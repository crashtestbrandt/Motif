# Architecture Decision Record (ADR)

## Title
ADR-0010: Knowledge graph is authoritative; no event log, no LiveView-side cache

## Status
Accepted — 2026-05-18 — Owner: Brandt Frazier

## Context
Once we have a graph DB (ADR-0003), a write coordinator (ADR-0006), and per-player chat sessions, several tempting auxiliary stores present themselves:

- An **event log** of all intents, for replay/audit/branching.
- A per-`gen_statem` **in-process cache** of the snapshot, to avoid a round-trip per intent.
- A per-LiveView **cached view** of game state, to render the chat pane quickly.

Each of these is a parallel source of truth that can drift from the graph. Drift is invisible until it's a bug.

## Decision
**The Neo4j graph is the sole authoritative source of game state.**

- No event log (yet). Mutations are applied directly to the graph and not retained as events.
- No persistent caches in the `gen_statem`. It may hold a transient snapshot for the duration of a single intent call; nothing across calls.
- No LiveView-side cache of game state. LiveView fetches state from the engine (via MCP `get_game_state` / `view_for`) on every render that needs it.

## Rationale
- Single source of truth eliminates an entire class of drift bugs.
- At Clue scale, graph reads are cheap; the optimization a cache would buy is invisible.
- Crash recovery is trivial: kill the `gen_statem`, restart, reload from graph; LiveView is stateless w.r.t. game truth.
- The mutation contract (ADR-0006) becomes verifiable: replay an intent sequence against an empty graph and assert isomorphism to the original final state.

**Alternatives considered:**
- **Event sourcing (with Commanded)**: powerful, but adds a second consistency surface and obscures "what does the world look like right now." Reconsider only if replay, branching, or audit becomes a hard product requirement — and only then via a new ADR.
- **Snapshot cache in `gen_statem`**: marginal speedup, large drift risk. Wait until measurements demand it.
- **LiveView state cache**: tempting for UX latency, but the LLM-mediated turn cycle is the bigger latency contributor; UI-state caching is not where to optimize.

## Consequences
**Positive**
- One place to look for "what is happening in this game right now."
- Determinism test (replay → isomorphism) is meaningful.
- Easy to share the graph live with humans during dev via Neo4j Browser.

**Negative**
- Every read pays a Cypher round-trip. Fine at Clue scale.
- No free audit trail. If we want to know "how did we get to this state?" we either reconstruct from chat transcripts or add the event log later.

**Future considerations**
- A future need for audit/replay/branching is the trigger for an event-log ADR.
- A future scaling problem (Risk 3 in plan: snapshot-load too expensive for big games) is the trigger for a partial-views or caching ADR.

## References
- `doc/plan/primary-goal-prototype-and-hazy-sparrow.md` — Architecture decisions § Rule purity, § Process model
- ADR-0003 (Neo4j), ADR-0006 (rule engine and write coordinator)
