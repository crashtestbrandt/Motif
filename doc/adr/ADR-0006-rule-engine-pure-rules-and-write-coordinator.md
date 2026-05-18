# Architecture Decision Record (ADR)

## Title
ADR-0006: Rule engine — pure rule functions + per-game `gen_statem` write coordinator

## Status
Accepted — 2026-05-18 — Owner: Brandt Frazier

## Context
ADR-0001 establishes that the knowledge graph is mutated only by the rule engine. We must decide *how* the rule engine works. Forces:

- Rules should be deterministic and testable in isolation.
- Concurrent intents from different players (or the same player's chat client retrying) must be serialized per game.
- The graph is the authoritative source of truth (ADR-0010); we don't want a parallel in-memory truth that can drift.
- The owner wants exposure to idiomatic OTP patterns including `gen_statem`.

## Decision
Two cooperating pieces:

1. **Pure rule functions.** A rule pack (Elixir module implementing a behaviour, ADR-0007) exposes:
   ```elixir
   @callback apply_intent(snapshot :: map(), intent :: map()) ::
     {:ok, mutations :: [Cypher.Mutation.t()]} | {:error, reason :: term()}
   ```
   These functions are pure: same `(snapshot, intent)` → same result, no I/O, no time, no randomness *except* through explicit injected seeds.

2. **Per-game `gen_statem` write coordinator.** One process per active game, supervised by a `DynamicSupervisor`, registered in a `Registry` keyed by `game_id`. Its only job per intent:
   ```
   load snapshot from Neo4j
     → call pure rule
     → write mutations in a single Neo4j transaction
     → reply to caller
   ```
   It holds no state beyond a Neo4j session handle and a brief turn cursor for invariants.

## Rationale
- Pure rules are trivially unit-testable: feed a snapshot map + intent, assert mutations.
- The `gen_statem` provides the serialization point so two simultaneous intents don't race the graph; the BEAM gives us this almost for free.
- "Load-compute-write" per intent at Clue scale is microseconds; the simplicity is worth more than the optimization it forecloses.
- Idiomatic OTP — meets the learning goal.

**Alternatives considered:**
- **Event sourcing** (e.g. `commanded`, an explicit event log): excellent for replay/branching/audit but adds a whole layer we don't need to validate the four assumptions in ADR-0001. Defer to a future ADR if/when replay or branching is in scope.
- **Cache snapshot in the gen_statem**: avoids the round-trip but introduces a second source of truth (the cache vs. the graph). Rejected on integrity grounds.
- **Direct function calls without a coordinator**: races become possible. Rejected.

## Consequences
**Positive**
- Rule logic is unit-testable without Neo4j running.
- Crash recovery for a game is "restart the `gen_statem`; reload from graph."
- Determinism is verifiable: replay an intent sequence → assert isomorphic graph.

**Negative**
- Every intent pays a graph read + graph write. Fine at Clue scale; may not generalize (Risk 3 in plan).
- "Snapshot" shape is a contract between the rule pack and the loader — must stay in lockstep across rule packs.

**Future considerations**
- If a future game has state too large to load per intent, partial views or a read replica may be needed. That should be a new ADR.
- If audit/replay becomes a hard requirement, layering an event log on top of mutations should be a new ADR.

## References
- `doc/plan/primary-goal-prototype-and-hazy-sparrow.md` — Architecture decisions § Rule purity
- ADR-0001 (boundaries), ADR-0007 (rule pack behaviour), ADR-0010 (graph authority)
- Erlang `gen_statem` docs: https://www.erlang.org/doc/man/gen_statem.html
