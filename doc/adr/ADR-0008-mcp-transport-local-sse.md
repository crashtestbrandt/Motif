# Architecture Decision Record (ADR)

## Title
ADR-0008: MCP transport — SSE on `127.0.0.1` (not in-process)

## Status
Accepted — 2026-05-18 — Owner: Brandt Frazier

## Context
The MCP boundary (ADR-0001 assumption 2) is one of the prototype's central theses: the LLM may only touch the engine via MCP. Both the MCP server (engine side) and MCP client (LiveView side) live in the same BEAM node during the prototype.

`ex_mcp` supports multiple transports — stdio, SSE over HTTP, WebSocket — and, in principle, in-process abstractions. We must pick one for local dev.

## Decision
Run MCP over **Server-Sent Events (SSE) on `127.0.0.1`**. Even though server and client are in the same BEAM node, they speak through a localhost HTTP loopback rather than via in-process Elixir function calls.

## Rationale
- The whole prototype is a test of "LLM only touches engine via MCP." An in-process transport silently lets code reach across the boundary in a debugging moment, and the integrity test is then compromised in a way we won't notice.
- Localhost SSE costs negligible latency at Clue scale (one message per intent, sub-millisecond loopback overhead).
- A wire-level transport makes every privilege escalation visible — we can tap the SSE stream to audit what the LLM is actually allowed to see and do.
- SSE specifically (over WebSocket or stdio) because: (a) it's the most common transport in current MCP clients, (b) it's trivially routable through Phoenix endpoints, and (c) it doesn't require the bidirectional framing that WS does, while still supporting server-pushed events for things like progress notifications.

**Alternatives considered:**
- **In-process** (ex_mcp's direct call transport, if any): fastest, but invisible boundary. Rejected for integrity reasons (this is *the* boundary we're testing).
- **stdio**: works for single-client CLI scenarios, but each LiveView session would need its own engine subprocess — operationally weird in a single BEAM node.
- **WebSocket**: viable, slightly more capable than SSE, but more framing complexity than we need; reconsider if/when we add bidirectional cues.

## Consequences
**Positive**
- The MCP wire is observable — we can capture and replay it for tests.
- Swapping transports later (stdio for CLI, WS for richer cues) is a config change, not a refactor.
- Two players in two browsers each get their own SSE stream — natural session boundary (ADR-0009).

**Negative**
- A loopback HTTP layer to maintain in dev, including TLS-or-not decisions later.
- Slight latency penalty vs in-process (negligible at prototype scale, possibly relevant at LLM-driven scale where every ms compounds with API latency).

**Future considerations**
- If/when the engine and chat tier are colocated in production and we want one less moving part, stdio or unix-domain-socket transports are possible.
- The disprove sub-turn (Risk 2 in plan) may require server-initiated cues to specific player sessions; SSE supports server→client push but bidirectional intent flow may push us to WebSocket — track and decide separately.

## References
- `doc/plan/primary-goal-prototype-and-hazy-sparrow.md` — Architecture decisions § MCP transport
- ADR-0001 (boundaries), ADR-0005 (ex_mcp), ADR-0009 (session auth)
- MCP transport spec: https://modelcontextprotocol.io/specification
