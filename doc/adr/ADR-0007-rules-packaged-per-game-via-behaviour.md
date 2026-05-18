# Architecture Decision Record (ADR)

## Title
ADR-0007: Rules packaged per-game via an Elixir behaviour

## Status
Accepted — 2026-05-18 — Owner: Brandt Frazier

## Context
The aspirational scope of Motif is to host arbitrary tabletop RPGs — Clue, D&D, GURPS, Eden, etc. — over the same engine, MCP boundary, and knowledge graph. The first concrete rules package is Clue. We need a contract that:

- Lets the engine load a game without knowing which game it is.
- Keeps each game's rules in a single Elixir module/namespace, so a new game can be added without forking the engine.
- Composes with the pure-rules + write-coordinator decision (ADR-0006).

## Decision
Define an Elixir **behaviour** named `MotifEngine.Rules`. Each game is one Elixir module that `@behaviour MotifEngine.Rules` and exposes:

```elixir
@callback setup(opts :: keyword()) :: {:ok, [Cypher.Mutation.t()]} | {:error, term()}
@callback legal_actions(snapshot :: map(), player_id :: String.t()) :: [intent_shape :: map()]
@callback apply_intent(snapshot :: map(), intent :: map()) ::
            {:ok, [Cypher.Mutation.t()]} | {:error, term()}
@callback view_for(snapshot :: map(), player_id :: String.t()) :: map()
```

- `setup/1` builds the initial graph (deal cards, place pawns, pick solution, etc.).
- `legal_actions/2` is read-only: returns the set of intents the caller may issue now.
- `apply_intent/3` is the pure rule function from ADR-0006.
- `view_for/2` returns the LLM-facing projection of state visible to a given player (used by MCP `get_game_state`-style tools).

A `:Game` node carries the fully-qualified module name of its rules pack; the engine dispatches all four callbacks via that module.

## Rationale
- Behaviours are the idiomatic Elixir mechanism for "swappable strategy" — compile-time checked, no dynamic loading hacks.
- All four callbacks are pure (modulo `setup`, which produces mutations but performs no I/O itself), which keeps them unit-testable.
- A small contract surface (4 callbacks) lowers the cost of adding a new game.

**Alternatives considered:**
- **Protocols** (Elixir's `defprotocol`): more flexible but unnecessary since a game is referenced by module, not by data type.
- **Dynamic rule DSL / data-driven rules** (e.g. JSON rule specs): defers code generation problems and weakens type-checking. Possibly worth a future ADR for a *runtime-pluggable* second-tier rules layer, but the foundation should be Elixir code.
- **One giant module per game** vs **a tree of helpers**: the behaviour contract is at the top-level module; the implementation can decompose internally as the game requires.

## Consequences
**Positive**
- Adding a new game = add one new module + tests, no engine changes.
- Cross-game invariants (e.g. "every `apply_intent` either returns mutations or an error reason") are enforced by the behaviour.
- Clue rules and engine concerns stay in separate files even before they get a separate app.

**Negative**
- Some games may not naturally fit four callbacks (e.g. games with phases that need richer lifecycle hooks). The behaviour will need careful extension — and behaviour changes ripple to every implementer.
- Snapshot shape is implicit across all rule packs; needs a documented contract.

**Future considerations**
- If/when a second game lands, evaluate whether a fifth callback (`teardown/2`, `tick/2`, ...) is justified.
- If runtime-loadable rule packs become a goal, consider distillation to a data DSL — but that's a separate decision.

## References
- ADR-0001 (boundaries), ADR-0006 (rule engine), ADR-0011 (umbrella layout: rules pack lives inside `motif_engine` until a second game arrives)
- Elixir behaviours: https://hexdocs.pm/elixir/typespecs.html#behaviours
