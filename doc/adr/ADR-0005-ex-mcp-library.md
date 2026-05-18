# Architecture Decision Record (ADR)

## Title
ADR-0005: `ex_mcp` as the MCP server and client library

## Status
Accepted — 2026-05-18 — Owner: Brandt Frazier

## Context
The architecture (ADR-0001) requires that the LLM communicate with the engine exclusively over MCP (Model Context Protocol). Therefore we need:

- An **MCP server** in the engine, exposing tools the LLM can call.
- An **MCP client** in the LiveView session, so the LLM's `tool_use` requests are routed through the MCP wire rather than via direct function calls.

The Elixir MCP ecosystem has several entrants as of early 2026 (e.g. `ex_mcp`, `hermes_mcp`, `mcp`, `conduit_mcp`). `ex_mcp` is the most feature-complete: stdio, SSE, and WebSocket transports; both client and server; documented troubleshooting; transport-agnostic abstractions.

## Decision
Use **`ex_mcp`** (Hex: https://hex.pm/packages/ex_mcp, GitHub: https://github.com/azmaveth/ex_mcp) for both the server and the client side of the MCP boundary.

## Rationale
- Provides both client and server in one library — no need to mix two libraries with potentially different semantics on either side of the boundary.
- Transport-agnostic API lets us use SSE locally (ADR-0008) and swap later if needed.
- Active maintenance and documented stdio integration with common MCP clients.

**Alternatives considered:**
- `hermes_mcp`: Phoenix-integrated but smaller scope.
- `mcp` / `conduit_mcp` / `elixir_mcp_server`: each less complete than `ex_mcp` along at least one axis (transport coverage, client+server symmetry, or maturity).
- Writing our own: defensible long-term but defeats the prototype's velocity.

## Consequences
**Positive**
- Single dependency for both sides of the MCP boundary.
- Transport choice is a config decision, not a code rewrite.

**Negative**
- Pre-1.0 library; expect API churn. Pin the version.
- We commit to whatever MCP spec versions `ex_mcp` tracks; if Anthropic ships features `ex_mcp` lags on, we may need to patch or upstream.

**Future considerations**
- If `ex_mcp` stalls or its design conflicts with how we want server-initiated cues to work (see Risk 2 in plan, relevant to disprove sub-turn), revisit — but a replacement would itself be an ADR.

## References
- `ex_mcp` on Hex: https://hex.pm/packages/ex_mcp
- MCP spec: https://modelcontextprotocol.io
- ADR-0001 (architectural boundaries), ADR-0008 (MCP transport choice), ADR-0009 (session auth in MCP)
