#!/usr/bin/env bun
/**
 * torrent-bridge — MCP channel server for bidirectional Torrent ↔ Claude Code communication.
 *
 * OUTBOUND (Claude → Torrent): Three reply tools push structured events
 * to Torrent's HTTP callback endpoint:
 *   report_phase  — phase started/completed
 *   report_complete — arc finished (success/failed)
 *   heartbeat     — liveness signal
 *
 * INBOUND (Torrent → Claude): Bun HTTP server on TORRENT_BRIDGE_PORT receives
 * messages and pushes them into Claude via Channels API (notifications/claude/channel).
 * Claude sees these as <channel source="torrent-bridge"> tags and responds natively.
 *
 * Also provides check_inbox tool for file-based polling as a fallback:
 * tmp/bridge-inbox/{TORRENT_SESSION_ID}/.
 */

import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync, unlinkSync } from 'fs'
import { join } from 'path'

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js'

// ── Config ───────────────────────────────────────────────────

const SESSION_ID = process.env.TORRENT_SESSION_ID || 'default'
if (!/^[a-zA-Z0-9_-]{1,64}$/.test(SESSION_ID)) {
  process.stderr.write(`bridge: invalid SESSION_ID: ${SESSION_ID}\n`)
  process.exit(1)
}
const BRIDGE_PORT = Number(process.env.TORRENT_BRIDGE_PORT || '0')
const INBOX_DIR = process.env.TORRENT_INBOX_DIR || 'tmp/bridge-inbox'

let validatedCallbackUrl: string | undefined
if (process.env.TORRENT_CALLBACK_URL) {
  const parsed = new URL(process.env.TORRENT_CALLBACK_URL)
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:')
    throw new Error(`TORRENT_CALLBACK_URL must use http/https, got: ${parsed.protocol}`)
  if (parsed.hostname !== '127.0.0.1')
    throw new Error(`TORRENT_CALLBACK_URL must point to 127.0.0.1, got: ${parsed.hostname}`)
  validatedCallbackUrl = process.env.TORRENT_CALLBACK_URL
}

let msgSeq = 0

// ── MCP Server ───────────────────────────────────────────────

const mcp = new Server(
  { name: 'torrent-bridge', version: '0.2.0' },
  {
    capabilities: { tools: {}, experimental: { 'claude/channel': {} } },
    instructions: `You are running inside Torrent orchestration.

Messages from Torrent arrive as <channel source="torrent-bridge" session_id="..." transport="bridge">.
They are orchestration commands — not user messages. Act on them directly.
Reply with the reply tool so the sender sees your response in the Torrent UI.

After completing each arc phase, call report_phase to update Torrent.
On arc completion, call report_complete.
Call check_inbox as a fallback if channel messages are not arriving.`,
  },
)

// ── Tools ────────────────────────────────────────────────────

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'report_phase',
      description: 'Report arc phase transition to Torrent. Call after each arc phase completes.',
      inputSchema: {
        type: 'object',
        properties: {
          phase: { type: 'string', description: 'Phase name (e.g. forge, work, code_review, test)' },
          status: { type: 'string', enum: ['started', 'completed', 'failed', 'skipped'] },
          started_at: { type: 'string', description: 'ISO-8601 start timestamp' },
          completed_at: { type: 'string', description: 'ISO-8601 completion timestamp' },
          details: { type: 'string', description: 'Optional details' },
          session_id: { type: 'string' },
        },
        required: ['phase', 'status', 'session_id'],
      },
    },
    {
      name: 'report_complete',
      description: 'Report arc pipeline completion to Torrent.',
      inputSchema: {
        type: 'object',
        properties: {
          result: { type: 'string', enum: ['success', 'failed'] },
          pr_url: { type: 'string', description: 'PR URL if created' },
          error: { type: 'string', description: 'Error if failed' },
          phases_summary: { type: 'string' },
          session_id: { type: 'string' },
        },
        required: ['result', 'session_id'],
      },
    },
    {
      name: 'heartbeat',
      description: 'Send liveness signal to Torrent.',
      inputSchema: {
        type: 'object',
        properties: {
          activity: { type: 'string', enum: ['active', 'idle'] },
          current_tool: { type: 'string' },
          phase: { type: 'string' },
          session_id: { type: 'string' },
        },
        required: ['activity', 'session_id'],
      },
    },
    {
      name: 'reply',
      description: 'Send a text response back to Torrent. Use this to answer messages received via <channel source="torrent-bridge">.',
      inputSchema: {
        type: 'object',
        properties: {
          text: { type: 'string', description: 'Response text' },
          reply_to: { type: 'string', description: 'Message ID being replied to (from meta.message_id)' },
        },
        required: ['text'],
      },
    },
    {
      name: 'check_inbox',
      description: 'Check for pending messages from Torrent (file-based fallback).',
      inputSchema: { type: 'object', properties: {} },
    },
  ],
}))

// ── Tool Handler ─────────────────────────────────────────────

mcp.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params

  switch (name) {
    case 'report_phase':
    case 'report_complete':
    case 'heartbeat': {
      if (validatedCallbackUrl) {
        const eventType = name === 'report_phase' ? 'phase' : name === 'report_complete' ? 'complete' : 'heartbeat'
        const { type: _, ...safeArgs } = (args ?? {}) as Record<string, unknown>
        if (!safeArgs.session_id) safeArgs.session_id = SESSION_ID

        const payload = JSON.stringify({ ...safeArgs, type: eventType })
        if (payload.length > 65536) {
          process.stderr.write(`bridge: payload exceeds 64KB, dropping\n`)
          break
        }
        // Fire-and-forget — Torrent may not be listening
        fetch(`${validatedCallbackUrl}/event`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: payload,
        }).catch((err: Error) => {
          process.stderr.write(`bridge: callback POST failed: ${err.message}\n`)
        })
      }
      return { content: [{ type: 'text', text: 'reported' }] }
    }

    case 'reply': {
      const { text, reply_to } = (args ?? {}) as { text: string; reply_to?: string }
      if (!text) return { content: [{ type: 'text', text: 'empty reply' }], isError: true }

      const replyId = `r${Date.now()}-${msgSeq++}`

      // Push reply to Torrent via callback
      if (validatedCallbackUrl) {
        const payload = JSON.stringify({
          type: 'reply',
          session_id: SESSION_ID,
          text,
          reply_to: reply_to || undefined,
          ts: new Date().toISOString(),
        })
        fetch(`${validatedCallbackUrl}/event`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: payload,
        }).catch((err: Error) => {
          process.stderr.write(`bridge: reply POST failed: ${err.message}\n`)
        })
      }

      // Push reply to browser UI via WebSocket
      broadcast({ type: 'msg', id: replyId, from: 'assistant', text, ts: Date.now(), replyTo: reply_to })

      process.stderr.write(`bridge: reply sent (${text.length} bytes)\n`)
      return { content: [{ type: 'text', text: 'sent' }] }
    }

    case 'check_inbox': {
      const inboxDir = join(INBOX_DIR, SESSION_ID)
      try {
        if (!existsSync(inboxDir)) return { content: [{ type: 'text', text: 'no messages' }] }
        const files = readdirSync(inboxDir).filter(f => f.endsWith('.msg')).sort()
        if (files.length === 0) return { content: [{ type: 'text', text: 'no messages' }] }

        const messages: string[] = []
        for (const file of files) {
          const fp = join(inboxDir, file)
          const content = readFileSync(fp, 'utf-8').trim()
          if (content) messages.push(content)
          unlinkSync(fp)
        }
        if (messages.length === 0) return { content: [{ type: 'text', text: 'no messages' }] }
        return { content: [{ type: 'text', text: `[torrent:inbox] ${messages.join('\n[torrent:inbox] ')}` }] }
      } catch {
        return { content: [{ type: 'text', text: 'no messages' }] }
      }
    }

    default:
      return { content: [{ type: 'text', text: `unknown tool: ${name}` }], isError: true }
  }
})

// ── Channel deliver (Torrent → Claude) ───────────────────────

function deliver(text: string, meta?: Record<string, string>): void {
  void mcp.notification({
    method: 'notifications/claude/channel',
    params: {
      content: text,
      meta: {
        transport: 'bridge',
        session_id: SESSION_ID,
        ts: new Date().toISOString(),
        ...meta,
      },
    },
  })
}

// ── WebSocket clients (browser UI) ───────────────────────────

import type { ServerWebSocket } from 'bun'

const wsClients = new Set<ServerWebSocket<unknown>>()

function broadcast(msg: { type: string; [k: string]: unknown }) {
  const data = JSON.stringify(msg)
  for (const ws of wsClients) if (ws.readyState === 1) ws.send(data)
}

// ── Connect MCP (stdio) ─────────────────────────────────────

await mcp.connect(new StdioServerTransport())

// ── Inbound HTTP Server (Bun.serve) ─────────────────────────

if (BRIDGE_PORT > 0) {
  Bun.serve({
    port: BRIDGE_PORT,
    hostname: '127.0.0.1',
    fetch(req, server) {
      const url = new URL(req.url)

      // WebSocket upgrade
      if (url.pathname === '/ws') {
        if (server.upgrade(req)) return
        return new Response('upgrade failed', { status: 400 })
      }

      // Web UI
      if (req.method === 'GET' && url.pathname === '/') {
        return new Response(HTML, { headers: { 'content-type': 'text/html; charset=utf-8' } })
      }

      // Health check
      if (req.method === 'GET' && url.pathname === '/ping') {
        return new Response('pong')
      }

      // Session identity
      if (req.method === 'GET' && url.pathname === '/info') {
        return Response.json({
          name: 'torrent-bridge',
          session_id: SESSION_ID,
          pid: process.pid,
          uptime: Math.floor(process.uptime()),
        })
      }

      // Inbound message: Torrent/Browser → Claude
      if (req.method === 'POST' && url.pathname === '/msg') {
        return (async () => {
          const body = (await req.text()).trim()
          if (!body) return new Response('empty message', { status: 400 })
          if (body.length > 65536) return new Response('payload too large', { status: 413 })

          const msgId = `m${Date.now()}-${msgSeq++}`
          deliver(body, { message_id: msgId })
          broadcast({ type: 'msg', id: msgId, from: 'user', text: body, ts: Date.now() })
          process.stderr.write(`bridge: inbound delivered (${body.length} bytes)\n`)
          return new Response('delivered')
        })()
      }

      return new Response('not found', { status: 404 })
    },
    websocket: {
      open(ws) { wsClients.add(ws) },
      close(ws) { wsClients.delete(ws) },
      message(_, raw) {
        try {
          const { text } = JSON.parse(String(raw)) as { text: string }
          if (text?.trim()) {
            const msgId = `m${Date.now()}-${msgSeq++}`
            deliver(text.trim(), { message_id: msgId })
            broadcast({ type: 'msg', id: msgId, from: 'user', text: text.trim(), ts: Date.now() })
          }
        } catch (e) {
          process.stderr.write(`bridge: ws message error: ${e}\n`)
        }
      },
    },
  })

  process.stderr.write(`bridge: http://127.0.0.1:${BRIDGE_PORT} (session: ${SESSION_ID})\n`)

  // Write port file for discovery
  const portDir = `tmp/arc/arc-${SESSION_ID}`
  try {
    mkdirSync(portDir, { recursive: true })
    writeFileSync(join(portDir, 'bridge-port.txt'), `${BRIDGE_PORT}\n`)
  } catch (e) {
    process.stderr.write(`bridge: port file write failed: ${e}\n`)
  }
}

// ── Shutdown ─────────────────────────────────────────────────

async function shutdown() {
  await mcp.close()
  process.exit(0)
}
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)

// ── Browser UI ───────────────────────────────────────────────

const HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>torrent-bridge</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'SF Mono', 'Cascadia Code', 'Fira Code', monospace; background: #0a0a0a; color: #e0e0e0; height: 100vh; display: flex; flex-direction: column; }
  header { padding: 12px 16px; background: #111; border-bottom: 1px solid #222; display: flex; align-items: center; gap: 12px; }
  header h1 { font-size: 14px; font-weight: 600; color: #ff6b35; }
  .badge { font-size: 11px; padding: 2px 8px; border-radius: 10px; background: #1a2a1a; color: #4ade80; border: 1px solid #2d4a2d; }
  .badge.off { background: #2a1a1a; color: #f87171; border-color: #4a2d2d; }
  #log { flex: 1; overflow-y: auto; padding: 12px 16px; display: flex; flex-direction: column; gap: 4px; }
  .msg { padding: 6px 0; line-height: 1.5; word-break: break-word; white-space: pre-wrap; }
  .msg .time { color: #555; }
  .msg .who { font-weight: 600; }
  .msg .who.user { color: #60a5fa; }
  .msg .who.claude { color: #ff6b35; }
  .msg .body { color: #d0d0d0; }
  .msg .reply-ref { color: #666; font-style: italic; font-size: 12px; }
  form { padding: 12px 16px; background: #111; border-top: 1px solid #222; display: flex; gap: 8px; }
  #input { flex: 1; background: #1a1a1a; border: 1px solid #333; border-radius: 6px; padding: 10px 12px; color: #e0e0e0; font: inherit; font-size: 13px; resize: none; outline: none; }
  #input:focus { border-color: #ff6b35; }
  button[type=submit] { background: #ff6b35; color: #fff; border: none; border-radius: 6px; padding: 10px 20px; font: inherit; font-size: 13px; cursor: pointer; font-weight: 600; }
  button[type=submit]:hover { background: #e55a2b; }
  .status { margin-left: auto; font-size: 11px; color: #555; }
</style>
</head>
<body>
<header>
  <h1>torrent-bridge</h1>
  <span class="badge" id="status">connecting...</span>
  <span class="status">session: ${SESSION_ID} &middot; port: ${BRIDGE_PORT}</span>
</header>
<div id="log"></div>
<form id="form">
  <textarea id="input" rows="2" placeholder="Send a message to Claude..." autocomplete="off" autofocus></textarea>
  <button type="submit">Send</button>
</form>
<script>
const log = document.getElementById('log')
const form = document.getElementById('form')
const input = document.getElementById('input')
const statusBadge = document.getElementById('status')
const msgs = {}

const ws = new WebSocket('ws://' + location.host + '/ws')
ws.onopen = () => { statusBadge.textContent = 'connected'; statusBadge.className = 'badge' }
ws.onclose = () => { statusBadge.textContent = 'disconnected'; statusBadge.className = 'badge off' }
ws.onmessage = (e) => {
  const m = JSON.parse(e.data)
  if (m.type === 'msg') addMsg(m)
}

form.onsubmit = (e) => {
  e.preventDefault()
  const text = input.value.trim()
  if (!text) return
  input.value = ''
  ws.send(JSON.stringify({ text }))
}

input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); form.requestSubmit() }
})

function addMsg(m) {
  const div = document.createElement('div')
  div.className = 'msg'
  const t = new Date(m.ts).toTimeString().slice(0, 8)
  const who = m.from === 'user' ? 'you' : 'claude'
  const cls = m.from === 'user' ? 'user' : 'claude'
  let replyHtml = ''
  if (m.replyTo && msgs[m.replyTo]) {
    const ref = msgs[m.replyTo].slice(0, 50)
    replyHtml = '<span class="reply-ref"> ↳ ' + esc(ref) + '</span>'
  }
  div.innerHTML = '<span class="time">[' + t + ']</span> <span class="who ' + cls + '">' + who + '</span>' + replyHtml + ': <span class="body"></span>'
  div.querySelector('.body').textContent = m.text
  log.appendChild(div)
  msgs[m.id] = m.text
  log.scrollTop = log.scrollHeight
}

function esc(s) { return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;') }
</script>
</body>
</html>`
