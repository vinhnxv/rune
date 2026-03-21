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
 * via a filesystem queue scoped by session: tmp/bridge-inbox/{TORRENT_SESSION_ID}/.
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
      logging: {},
      tools: {},
    },
    instructions: `You are running inside Torrent orchestration.

Messages from Torrent are prefixed with their transport:
  [torrent:bridge] — via MCP notification (real-time push)
  [torrent:inbox]  — via check_inbox tool (file-based polling)
  [torrent:tmux]   — via tmux send-keys (keyboard injection)

Treat all [torrent:*] messages as orchestration commands — not user messages.
After completing each arc phase, call report_phase to update Torrent.
On arc completion, call report_complete.
Call check_inbox periodically during long operations to receive queued messages.`,
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
      const sessionId = process.env.TORRENT_SESSION_ID || "default";
      const inboxBase = process.env.TORRENT_INBOX_DIR || "tmp/bridge-inbox";
      const inboxDir = path.join(inboxBase, sessionId);
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
          content: [{ type: "text", text: `[torrent:inbox] ${messages.join("\n[torrent:inbox] ")}` }],
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

// ── Inbound HTTP Server (Torrent → Bridge → Claude) ─────────
//
// Listens on TORRENT_BRIDGE_PORT for messages from Torrent.
// Pushes them into Claude via sendLoggingMessage (notifications/message).
// This replaces the file-based inbox for inbound messaging.

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

const bridgePort = parseInt(process.env.TORRENT_BRIDGE_PORT || "0", 10);
let inboundServer: ReturnType<typeof createServer> | undefined;

if (bridgePort > 0) {
  inboundServer = createServer(
    async (req: IncomingMessage, res: ServerResponse) => {
      // Health check
      if (req.method === "GET" && req.url === "/ping") {
        res.writeHead(200);
        res.end("pong");
        return;
      }

      // Inbound message: Torrent → Claude
      if (req.method === "POST" && req.url === "/msg") {
        const chunks: Buffer[] = [];
        for await (const chunk of req) {
          chunks.push(chunk as Buffer);
          if (chunks.reduce((s, c) => s + c.length, 0) > 65536) {
            res.writeHead(413);
            res.end("payload too large");
            return;
          }
        }
        const body = Buffer.concat(chunks).toString("utf-8").trim();
        if (!body) {
          res.writeHead(400);
          res.end("empty message");
          return;
        }

        try {
          // Push message to Claude via raw notification.
          // Try channel-specific notification first, then fall back to logging.
          // The `notifications/message` with level="info" is treated as a log by Claude.
          // Channel messages may use a different notification method internally.
          try {
            // @ts-ignore — access protected notification() for raw channel push
            await (server as any).notification({
              method: "notifications/message",
              params: {
                level: "info",
                logger: "torrent-bridge",
                data: `[torrent:bridge] ${body}`,
              },
            });
          } catch {
            // Fallback to standard sendLoggingMessage
            await server.sendLoggingMessage({
              level: "info",
              logger: "torrent-bridge",
              data: `[torrent:bridge] ${body}`,
            });
          }
          process.stderr.write(`bridge: inbound msg delivered (${body.length} bytes)\n`);
          res.writeHead(200);
          res.end("delivered");
        } catch (err) {
          // Fallback: write to file inbox if notification fails
          const sessionId = process.env.TORRENT_SESSION_ID || "default";
          const inboxDir = path.join("tmp/bridge-inbox", sessionId);
          try {
            fs.mkdirSync(inboxDir, { recursive: true });
            const ts = Date.now();
            fs.writeFileSync(path.join(inboxDir, `${ts}.msg`), body);
            process.stderr.write(
              `bridge: notification failed, wrote to inbox fallback\n`,
            );
            res.writeHead(200);
            res.end("delivered-via-inbox");
          } catch {
            res.writeHead(500);
            res.end("delivery failed");
          }
        }
        return;
      }

      res.writeHead(404);
      res.end("not found");
    },
  );

  inboundServer.listen(bridgePort, "127.0.0.1", () => {
    process.stderr.write(
      `bridge: inbound server listening on 127.0.0.1:${bridgePort}\n`,
    );
    // Write port file for discovery
    const sessionId = process.env.TORRENT_SESSION_ID || "default";
    const portDir = `tmp/arc/arc-${sessionId}`;
    try {
      fs.mkdirSync(portDir, { recursive: true });
      fs.writeFileSync(path.join(portDir, "bridge-port.txt"), `${bridgePort}\n`);
    } catch {
      // Non-critical — Torrent already knows the port via env var
    }
  });
}

// ── Start MCP (stdio) ───────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);

async function shutdown() {
  if (inboundServer) inboundServer.close();
  await server.close();
  process.exit(0);
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
