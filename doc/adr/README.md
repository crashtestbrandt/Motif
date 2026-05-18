# Architecture Decision Records

This directory contains the Architecture Decision Records (ADRs) for **Motif**. Each ADR captures one significant decision: the context that motivated it, what we chose, why, and what we're now committed to.

ADRs are **immutable once Accepted**. If the decision changes, write a new ADR that supersedes the old one (and update the old one's status to `Superseded by ADR-XXXX`).

See [CLAUDE.md](../../CLAUDE.md) for the criteria on when an ADR is required and how to author one.

## Index

| #    | Title                                                                                          | Status                |
|------|------------------------------------------------------------------------------------------------|-----------------------|
| 0001 | [Architectural boundaries — Player ↔ LLM ↔ MCP ↔ Rule Engine ↔ Knowledge Graph](ADR-0001-architectural-boundaries.md) | Accepted (2026-05-18) |
| 0002 | [Elixir + OTP as the implementation platform](ADR-0002-elixir-otp-platform.md)                  | Accepted (2026-05-18) |
| 0003 | [Neo4j as the knowledge graph store](ADR-0003-neo4j-as-knowledge-graph.md)                      | Accepted (2026-05-18) |
| 0004 | [`boltx` as the Elixir Neo4j driver](ADR-0004-boltx-neo4j-driver.md)                            | Accepted (2026-05-18) |
| 0005 | [`ex_mcp` as the MCP server and client library](ADR-0005-ex-mcp-library.md)                     | Accepted (2026-05-18) |
| 0006 | [Rule engine — pure rule functions + per-game `gen_statem` write coordinator](ADR-0006-rule-engine-pure-rules-and-write-coordinator.md) | Accepted (2026-05-18) |
| 0007 | [Rules packaged per-game via an Elixir behaviour](ADR-0007-rules-packaged-per-game-via-behaviour.md) | Accepted (2026-05-18) |
| 0008 | [MCP transport — SSE on `127.0.0.1`](ADR-0008-mcp-transport-local-sse.md)                       | Accepted (2026-05-18) |
| 0009 | [`player_id` bound at MCP session handshake, never as a tool argument](ADR-0009-player-id-bound-at-mcp-session.md) | Accepted (2026-05-18) |
| 0010 | [Knowledge graph is authoritative; no event log, no cache](ADR-0010-graph-is-authoritative.md)  | Accepted (2026-05-18) |
| 0011 | [Mix umbrella project layout with three apps](ADR-0011-umbrella-project-layout.md)              | Accepted (2026-05-18) |
| 0012 | [Player chat surface — Phoenix LiveView + direct Anthropic API](ADR-0012-phoenix-liveview-chat-surface.md) | Accepted (2026-05-18) |

## Template
New ADRs start from [`ADR-TEMPLATE.md`](ADR-TEMPLATE.md).
