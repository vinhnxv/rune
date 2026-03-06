---
title: "Real-Time Notifications"
date: 2026-03-07
mode: "roundtable"
quality_score: 0.85
quality_tier: "excellent"
workspace: "tmp/brainstorm-1709812345678"
advisors: ["user-advocate", "tech-realist", "devils-advocate"]
rounds_completed: 3
approach_selected: "WebSocket-based push notifications"
devise_ready: true
---

# Brainstorm: Real-Time Notifications

## What We're Building

A WebSocket-based real-time notification system that pushes updates to connected clients instantly. The system will support multiple notification channels (in-app, email digest, mobile push) with user-configurable preferences. Initial scope targets in-app notifications only, with email and mobile as future phases.

## Advisor Perspectives

### User Advocate

Users expect instant feedback when actions complete or when collaborators make changes. Current polling-based approach creates 5-30 second delays that break flow state. Research of existing `src/api/` routes shows 12 endpoints that could benefit from push notifications. Priority: collaborative editing notifications and deployment status updates.

### Tech Realist

Existing codebase uses Express.js with no WebSocket infrastructure. Recommended: Socket.IO for compatibility (already in ecosystem). The `src/middleware/auth.ts` session handling can be extended for WS auth. Database: add `notifications` table with read/unread status. Estimated complexity: moderate — foundational work needed but well-understood patterns.

### Devil's Advocate

Do we need real-time for all notification types? Email digests and deployment notifications can tolerate 30-second delays with existing polling. Suggested YAGNI approach: WebSocket only for collaborative editing (highest user pain), server-sent events for everything else. Simpler, fewer moving parts, proven at scale.

## Chosen Approach

**Approach**: WebSocket-based push notifications via Socket.IO

**Why**: Best balance of user experience and implementation complexity. Socket.IO provides fallback transports, reconnection handling, and room-based routing out of the box.

**Trade-offs accepted**:
- Additional server infrastructure (WebSocket connections are stateful)
- Slightly higher complexity than SSE for simple notifications

## Key Constraints

- Must work behind existing nginx reverse proxy configuration
- Authentication must reuse existing JWT token flow
- Must support horizontal scaling (multiple server instances)

## Non-Goals

- Mobile push notifications — deferred to Phase 2
- Email digest notifications — deferred to Phase 2
- Custom notification sounds/themes — not planned

## Constraint Classification

| Constraint | Priority | Rationale |
|------------|----------|-----------|
| JWT auth reuse | MUST | Security consistency, no parallel auth systems |
| Horizontal scaling | MUST | Production deployment requires multi-instance |
| Nginx compatibility | SHOULD | Current infra, but could reconfigure if needed |

## Success Criteria

- Notification delivery latency < 500ms (p95)
- Zero message loss during server restarts (graceful reconnection)

## Scope Boundary

### In-Scope
- WebSocket connection management
- In-app notification delivery
- Read/unread status tracking
- User notification preferences (on/off per channel)

### Out-of-Scope
- Mobile push (Phase 2)
- Email digest (Phase 2)
- Notification analytics dashboard

## Open Questions

- [ ] Redis pub/sub vs dedicated message broker for multi-instance routing?
- [ ] Notification retention policy — how long to keep read notifications?
- [ ] Rate limiting strategy for notification-heavy workflows?
