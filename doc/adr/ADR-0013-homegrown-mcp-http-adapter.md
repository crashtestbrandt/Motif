# Architecture Decision Record (ADR)

## Title
ADR-0013: Homegrown MCP-compatible HTTP+JSON-RPC adapter for the prototype

## Status
Accepted — 2026-05-18 — Owner: Brandt Frazier

## Context
ADR-0009 requires that `player_id` be **read by tool handlers from session-bound context** — never from tool arguments. This is the single most important hidden-information invariant in the prototype.

When implementing milestone 4 (the MCP server), I read `ex_mcp`'s `HttpPlug` source (~r0.7.4) and confirmed:

- The library deliberately keeps tool handlers isolated from the HTTP connection. The handler signature is `(request) -> response` and does **not** receive `conn`, headers, the bearer token, the session id, or any per-connection metadata.
- Authentication, when enabled, validates a bearer token but discards the token's claims — only `{:ok, _token_info}` is checked before dispatch.
- Session ids exist but are returned in response headers only; they are never passed into the handler.

There is no documented hook (`init_session`, `prepare_state`, etc.) that lets a handler initialize per-connection state with caller identity. ADR-0009 is therefore not implementable on `ex_mcp` 0.7.4 without modifying the library upstream.

The architectural test we want to run during this prototype is "session-bound identity makes forged `player_id` args inert." That test must work today; waiting on an upstream change would block milestones 4–7.

## Decision
Build a **minimal MCP-compatible HTTP+JSON-RPC adapter** inside `motif_mcp`:

- **Transport**: HTTP request/response over `Bandit` + `Plug.Router`, bound to `127.0.0.1:4001`.
- **Wire format**: JSON-RPC 2.0 — the same wire format MCP itself uses.
- **Methods implemented**: `tools/list` and `tools/call`. (Enough for the milestone-4 tool surface; more can be added in place.)
- **Session model**:
  - `POST /sessions` with body `{"token": "<opaque>"}` returns a fresh `session_id`. The server resolves the token to `(game_id, player_id)` via `MotifMcp.Auth` and stamps the session — *server-side only* — with that identity.
  - `POST /sessions/:session_id/rpc` carries JSON-RPC requests. The session id is the sole credential after handshake.
- **Tool handler signature**: `handle(ctx, args) :: {:ok, map()} | {:error, term()}` where `ctx :: %{player_id, game_id}` comes from the session. Tool modules must read identity from `ctx` only; they may never read `args["player_id"]` or `args["game_id"]`.
- **No SSE for now**. The prototype's request/response load is single-message-per-call; SSE is deferred until we need server-initiated cues (the disprove sub-turn, milestone 6).

This adapter is owned by `motif_mcp` and lives entirely inside this repo. It is **not** an attempt to compete with `ex_mcp`; it is a thin shim that lets ADR-0009 be honored today.

## Rationale
- **The architectural invariant is non-negotiable.** ADR-0009 is what makes hidden-information games possible at all. Ship something that satisfies it now, even if temporary.
- **Wire compatibility kept open.** Using JSON-RPC 2.0 means we can swap to `ex_mcp` (or any other MCP server) without changing the tool catalog, tool handlers, or the client. The adapter is the only piece that would be replaced.
- **Small footprint.** The whole adapter is ~6 small modules (Auth, SessionManager, Tool, Tools, JsonRpc, Router). Less code than an ex_mcp wrapper that bridges session context via ETS by `self()`, and far less fragile.

**Alternatives considered:**
- **Wrap `ex_mcp` with a Plug + ETS-by-`self()` bridge** to leak `player_id` into the handler. Rejected: ex_mcp may run SSE handlers in a different process than the connection plug, so `self()` keying breaks for that transport.
- **Patch `ex_mcp` upstream** to pass session context into handlers. Right long-term move, wrong scope for a prototype milestone. Tracking as a future contribution.
- **Defer the wire entirely** and dispatch tools via Elixir function calls in-process. Doesn't actually validate the "LLM only via MCP" boundary (assumption 2) at the wire level — half the point of the prototype.

## Consequences
**Positive**
- ADR-0009 is honored end-to-end, with a property test (`tools/list` schemas reject any `player_id` property) and a negative integration test (forged `player_id` in `arguments` is provably inert).
- We control the wire. Adding `initialize`, `tools/list_changed`, or other MCP methods is a small local change.
- No dependency on `ex_mcp`'s session API maturing.

**Negative**
- We own MCP wire-format conformance. If the spec evolves (it has and will), we have to track it.
- No SSE yet. Server-initiated cues (e.g. disprove sub-turn in milestone 6) will need either SSE or WebSockets added here — or a switch to a library that handles it well.
- Tooling around MCP (debug inspectors, third-party clients) expects standard transports; our minimal adapter may not be drop-in compatible with all of them.

**Future considerations**
- When `ex_mcp` (or a successor) exposes a session-context hook, evaluate replacing this adapter. The replacement is local to `motif_mcp` — tool modules don't change.
- SSE / WebSocket transport should land before milestone 6 if disprove requires server-initiated prompts.
- If we standardize on this adapter long-term, it should be tested against the [MCP Inspector](https://modelcontextprotocol.io/inspector) for conformance.

## References
- `apps/motif_mcp/lib/motif_mcp/router.ex`, `json_rpc.ex`, `auth.ex`, `session_manager.ex`, `tool.ex`, `tools.ex`
- ADR-0005 (ex_mcp) — partially superseded by this ADR for the prototype's server implementation
- ADR-0008 (MCP transport: SSE on localhost) — narrowed to "deferred until we need server-initiated cues"
- ADR-0009 (player_id at MCP session) — this ADR is the implementation that makes 0009 testable
- ex_mcp HttpPlug source (read 2026-05-18, version 0.7.4) — confirmed no session context in handler interface
- MCP spec: https://modelcontextprotocol.io/specification
