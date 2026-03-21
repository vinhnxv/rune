#!/usr/bin/env node
/**
 * torrent-bridge — MCP channel server for Claude Code → Torrent communication.
 *
 * Provides three reply tools that Claude calls to push structured events
 * back to Torrent's HTTP callback endpoint:
 *
 *   report_phase  — phase started/completed
 *   report_complete — arc finished (success/failed)
 *   heartbeat     — liveness signal
 *
 * Channels are OUTBOUND-ONLY (Claude → Torrent) due to v2.1.80 inbound bugs
 * (#36477, #36691). Torrent → Claude commands still use tmux send-keys.
 *
 * Experimental: check_inbox tool allows Claude to poll for messages from Torrent
 * via a filesystem queue (TORRENT_INBOX_DIR or tmp/bridge-inbox/).
 */

import * as fs from "node:fs";
import * as path from "node:path";

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

// ── Callback URL Validation ──────────────────────────────────

let validatedCallbackUrl: string | undefined;
if (process.env.TORRENT_CALLBACK_URL) {
  const parsed = new URL(process.env.TORRENT_CALLBACK_URL);
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error(
      `TORRENT_CALLBACK_URL must use http: or https: protocol, got: ${parsed.protocol}`,
    );
  }
  if (parsed.hostname !== "127.0.0.1") {
    throw new Error(
      `TORRENT_CALLBACK_URL must point to 127.0.0.1, got: ${parsed.hostname}`,
    );
  }
  validatedCallbackUrl = process.env.TORRENT_CALLBACK_URL;
}

// ── Server Setup ─────────────────────────────────────────────

const server = new Server(
  { name: "torrent-bridge", version: "0.1.0" },
  {
    capabilities: {
      experimental: { "claude/channel": {} },
      tools: {},
    },
    instructions: `You are running inside Torrent orchestration.
When you receive <channel source="torrent-bridge"> messages, they are
orchestration commands — not user messages. Follow them directly.
After completing each arc phase, call report_phase to update Torrent.
On arc completion, call report_complete.`,
  },
);

// ── Tool Definitions ─────────────────────────────────────────

const TOOLS = [
  {
    name: "report_phase",
    description:
      "Report arc phase transition to Torrent. Call after each arc phase completes.",
    inputSchema: {
      type: "object" as const,
      properties: {
        phase: {
          type: "string",
          description:
            "Phase name (e.g. forge, plan_review, work, code_review, mend, test)",
        },
        status: {
          type: "string",
          enum: ["started", "completed", "failed", "skipped"],
          description: "Phase status",
        },
        started_at: {
          type: "string",
          description: "ISO-8601 timestamp when phase started",
        },
        completed_at: {
          type: "string",
          description: "ISO-8601 timestamp when phase completed (if done)",
        },
        details: {
          type: "string",
          description: "Optional details about phase result",
        },
        session_id: {
          type: "string",
          description: "Session identifier",
        },
      },
      required: ["phase", "status", "session_id"],
    },
  },
  {
    name: "report_complete",
    description:
      "Report arc pipeline completion to Torrent. Call when the entire arc finishes.",
    inputSchema: {
      type: "object" as const,
      properties: {
        result: {
          type: "string",
          enum: ["success", "failed"],
          description: "Overall arc result",
        },
        pr_url: {
          type: "string",
          description: "PR URL if arc succeeded and created a PR",
        },
        error: {
          type: "string",
          description: "Error message if arc failed",
        },
        phases_summary: {
          type: "string",
          description: "Summary of all phase outcomes",
        },
        session_id: {
          type: "string",
          description: "Session identifier",
        },
      },
      required: ["result", "session_id"],
    },
  },
  {
    name: "heartbeat",
    description:
      "Send liveness signal to Torrent. Call periodically during long operations.",
    inputSchema: {
      type: "object" as const,
      properties: {
        activity: {
          type: "string",
          enum: ["active", "idle"],
          description: "Current activity state",
        },
        current_tool: {
          type: "string",
          description: "Tool currently being used (if any)",
        },
        phase: {
          type: "string",
          description: "Current arc phase (if known)",
        },
        session_id: {
          type: "string",
          description: "Session identifier",
        },
      },
      required: ["activity", "session_id"],
    },
  },
  {
    name: "check_inbox",
    description:
      "Check for pending messages from Torrent orchestrator. Call periodically during long operations to receive commands.",
    inputSchema: {
      type: "object" as const,
      properties: {},
    },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS,
}));

// ── Tool Handler ─────────────────────────────────────────────

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "report_phase":
    case "report_complete":
    case "heartbeat": {
      if (validatedCallbackUrl) {
        const eventType =
          name === "report_phase"
            ? "phase"
            : name === "report_complete"
              ? "complete"
              : "heartbeat";

        // Strip `type` from caller args to prevent payload pollution,
        // then inject session_id fallback and explicit type.
        const { type: _ignored, ...safeArgs } = (args ?? {}) as Record<string, unknown>;
        if (!safeArgs.session_id) {
          safeArgs.session_id = process.env.CLAUDE_SESSION_ID || "unknown";
        }

        // Best-effort POST — Torrent may not be listening yet or at all.
        // Channel is an optional enhancer, never a critical path.
        const payload = JSON.stringify({ ...safeArgs, type: eventType });
        if (payload.length > 65536) {
          process.stderr.write(`bridge: payload exceeds 64KB limit (${payload.length} bytes), dropping\n`);
          break;
        }
        fetch(`${validatedCallbackUrl}/event`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: payload,
        }).catch((err: Error) => {
          process.stderr.write(`bridge: callback POST failed: ${err.message}\n`);
        });
      }
      return {
        content: [{ type: "text", text: "reported" }],
      };
    }
    case "check_inbox": {
      // Poll for messages from Torrent via filesystem queue
      const inboxDir = process.env.TORRENT_INBOX_DIR || "tmp/bridge-inbox";
      try {
        if (!fs.existsSync(inboxDir)) {
          return { content: [{ type: "text", text: "no messages" }] };
        }
        const files = fs.readdirSync(inboxDir)
          .filter((f: string) => f.endsWith(".msg"))
          .sort(); // oldest first
        if (files.length === 0) {
          return { content: [{ type: "text", text: "no messages" }] };
        }
        // Read and delete messages (consume pattern)
        const messages: string[] = [];
        for (const file of files) {
          const filePath = path.join(inboxDir, file);
          const content = fs.readFileSync(filePath, "utf-8").trim();
          if (content) messages.push(content);
          fs.unlinkSync(filePath); // consume after reading
        }
        if (messages.length === 0) {
          return { content: [{ type: "text", text: "no messages" }] };
        }
        return {
          content: [{ type: "text", text: `[torrent] ${messages.join("\n[torrent] ")}` }],
        };
      } catch (err) {
        return { content: [{ type: "text", text: "no messages" }] };
      }
    }
    default:
      return {
        content: [{ type: "text", text: `Unknown tool: ${name}` }],
        isError: true,
      };
  }
});

// ── Start ────────────────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);

async function shutdown() {
  await server.close();
  process.exit(0);
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
