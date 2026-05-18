# Architecture Decision Record (ADR)

## Title
ADR-0012: Player chat surface — Phoenix LiveView + direct Anthropic API

## Status
Accepted — 2026-05-18 — Owner: Brandt Frazier
**Partially superseded by [ADR-0014](ADR-0014-self-hosted-llm-only.md) (2026-05-18)** — the Anthropic-API portion is replaced; Phoenix LiveView as the chat surface remains.

## Context
Each player needs a chat surface to interact with the LLM (ADR-0001 assumption 1). The chat surface needs to:

- Hold a per-player conversation with Claude (Anthropic API), including tool use.
- Open an authenticated MCP session to the engine (ADR-0009).
- Translate Claude's `tool_use` blocks into MCP tool calls and return `tool_result`s.
- Render messages in a browser, one pane per player.

The owner's learning goals include idiomatic Elixir, which Phoenix LiveView exercises substantially.

## Decision
Build a **Phoenix LiveView** application (`motif_web`, ADR-0011) where each player session is a LiveView process that:

1. Manages a streaming conversation with the Anthropic API (Claude) using `req` for HTTP and Claude's tool-use mechanism.
2. Holds an authenticated MCP client session against `motif_mcp` (over local SSE, ADR-0008).
3. Bridges Claude's `tool_use` ↔ MCP tool calls. Claude only sees the MCP tool catalog; LiveView is the trusted intermediary.

The Anthropic API is called directly (no managed agent layer). Prompt caching is configured per the Claude API skill when relevant.

## Rationale
- LiveView is the idiomatic Elixir way to drive a real-time, server-rendered UI; matches the learning goal.
- Direct API calls keep us close to the tool-use lifecycle, which is exactly what the prototype is investigating; managed-agent abstractions would hide the wire.
- A LiveView process per player gives natural session identity, isolation, and crash recovery aligned with the rest of the OTP design.

**Alternatives considered:**
- **BYO MCP client (Claude Desktop)**: fastest to a first playable game, but writes no chat-surface code and forecloses learning Phoenix. Rejected against the secondary goal.
- **JavaScript SPA + REST API**: more code in the wrong language and adds an HTTP layer we don't need.
- **Anthropic Managed Agents**: would simplify the tool loop, but hides exactly the part of the architecture under test.
- **CLI-only for the prototype**: defers the LLM thesis entirely; rejected because that thesis is half the point.

## Consequences
**Positive**
- One BEAM-native process per player session — identity, supervision, and presence come free.
- Tool-use loop is fully visible and tweakable; ideal for the prototype's questions about MCP boundaries.
- Two browser tabs = two players, locally; trivial multi-player dev.

**Negative**
- We hand-roll the Anthropic API integration (no first-party Elixir SDK at time of writing); minor friction.
- Streaming response handling, retry/backoff, and prompt caching are our problem.
- Browser-only UI (no native or mobile clients) until/unless we add them.

**Future considerations**
- If/when the chat surface needs to be richer than what LiveView gives us, consider a JS island for specific components rather than rewriting the whole UI.
- Server-initiated cues to specific players (Risk 2 in plan, disprove sub-turn) interact with LiveView via PubSub + MCP notifications; that integration may merit its own ADR.

## References
- `doc/plan/primary-goal-prototype-and-hazy-sparrow.md` — confirmed scope
- ADR-0001 (boundaries), ADR-0005 (ex_mcp), ADR-0008 (SSE transport), ADR-0009 (session auth), ADR-0011 (umbrella)
- Phoenix LiveView: https://hexdocs.pm/phoenix_live_view
- Anthropic API tool use: https://docs.anthropic.com/en/docs/build-with-claude/tool-use
