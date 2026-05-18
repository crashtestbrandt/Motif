# Architecture Decision Record (ADR)

## Title
ADR-0002: Elixir + OTP as the implementation platform

## Status
Accepted — 2026-05-18 — Owner: Brandt Frazier

## Context
The engine must:
- Host long-lived per-game state with crash-recovery semantics.
- Coordinate concurrent player sessions (one chat session per player, 2–6 per game).
- Expose an MCP server.
- Drive a multiplayer web UI.

A secondary purpose of Motif is for the owner to learn idiomatic Elixir, Cypher, and Neo4j patterns.

## Decision
Implement Motif in **Elixir** on the **BEAM**, using **OTP** primitives — supervisors, `GenServer`, `gen_statem`, `Registry`, `DynamicSupervisor`, behaviours — as the structural idiom for the engine. Use **Phoenix** for the web tier (see ADR-0012).

## Rationale
- OTP's process-per-game model maps cleanly to "one game = one supervised state machine"; crash recovery is "reload the game by id."
- BEAM concurrency makes hosting many simultaneous chat sessions (each waiting on Anthropic API + MCP traffic) cheap and isolated.
- The language is small enough that the owner's learning goal (idiomatic Elixir) is plausible within prototype scope.
- The MCP and Neo4j ecosystems on Elixir, while smaller than Python's, are sufficient for a prototype (see ADR-0004, ADR-0005).

**Alternatives considered:**
- **Python + asyncio**: largest MCP ecosystem, but loses BEAM's per-process isolation and supervision model. Doesn't serve the learning goal.
- **TypeScript + Node**: official MCP SDK is most mature here, but state-machine ergonomics and supervision semantics are weaker.
- **Go**: strong concurrency but no behaviour/protocol primitive and no supervision tree; loses what we'd want OTP for.

## Consequences
**Positive**
- Process model is a natural fit for "per-game state machine" and "per-player session."
- Supervision means crash recovery is essentially free at the OTP level.
- Owner gains hands-on idiomatic Elixir experience (secondary goal).

**Negative**
- Smaller MCP/AI ecosystem than Python; we commit to whichever Elixir MCP library we choose (ADR-0005).
- Slightly more friction integrating with the Anthropic API (no first-party Elixir SDK at time of writing); use `req` + manual JSON.

**Future considerations**
- If the Elixir MCP library proves too immature in practice, sidecar-ing a Python or TypeScript MCP host is possible — but would itself be a new ADR.

## References
- `doc/plan/primary-goal-prototype-and-hazy-sparrow.md`
- ADR-0004 (boltx), ADR-0005 (ex_mcp), ADR-0006 (gen_statem rule engine), ADR-0011 (umbrella layout), ADR-0012 (Phoenix LiveView)
