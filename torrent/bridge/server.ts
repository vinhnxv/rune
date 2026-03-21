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
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

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
      },
      required: ["phase", "status"],
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
      },
      required: ["result"],
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
      },
      required: ["activity"],
    },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS,
}));

// ── Tool Handler ─────────────────────────────────────────────

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const callbackUrl = process.env.TORRENT_CALLBACK_URL;

  switch (name) {
    case "report_phase":
    case "report_complete":
    case "heartbeat": {
      if (callbackUrl) {
        const eventType =
          name === "report_phase"
            ? "phase"
            : name === "report_complete"
              ? "complete"
              : "heartbeat";

        // Best-effort POST — Torrent may not be listening yet or at all.
        // Channel is an optional enhancer, never a critical path.
        fetch(`${callbackUrl}/event`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ type: eventType, ...args }),
        }).catch(() => {});
      }
      return {
        content: [{ type: "text", text: "reported" }],
      };
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
