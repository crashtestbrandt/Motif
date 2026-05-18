# Architecture Decision Record (ADR)

## Title
ADR-0011: Mix umbrella project layout with three apps

## Status
Accepted — 2026-05-18 — Owner: Brandt Frazier

## Context
The system has three reasonably orthogonal concerns:

1. The **engine** — rule behaviour, per-game `gen_statem`, `boltx` connection, Clue rule pack.
2. The **MCP boundary** — `ex_mcp` server, session auth, tool handlers.
3. The **web tier** — Phoenix LiveView panes and the Anthropic API client.

Mixing these in a single Phoenix app would compile cleanly but offers no compile-time enforcement of the architectural directionality (ADR-0001). The boundaries we're trying to *test* would not be reflected in the build graph.

## Decision
Use a Mix **umbrella project** with exactly three apps:

```
motif/
├── apps/
│   ├── motif_engine/   # rule behaviour, gen_statem, boltx Repo, Clue rules pack as a sub-module
│   ├── motif_mcp/      # ex_mcp server, session auth, tool handlers
│   └── motif_web/      # Phoenix LiveView + Anthropic client
├── config/             # shared config
└── mix.exs             # umbrella root
```

**Dependency arrows (compile-enforced):**
- `motif_mcp` depends on `motif_engine`. Engine knows nothing of MCP.
- `motif_web` depends on `motif_mcp`. Web knows nothing of the engine directly.
- `motif_engine` depends on nothing else internal.

The Clue rules pack lives **inside** `motif_engine` (as `MotifEngine.Rules.Clue`) until a second game arrives. Splitting it into its own app is premature ceremony for a prototype with one game.

## Rationale
- Umbrellas make app-to-app dependencies explicit in `mix.exs` and force you to declare cross-app imports — exactly the discipline we want for testing the architectural boundaries.
- A single Phoenix app would compile fine even if `MotifWeb` imported `MotifEngine` directly, silently bypassing the MCP boundary (the very assumption we're testing).
- Three apps is the minimum that reflects the three real concerns; more would be ceremony.

**Alternatives considered:**
- **Single Phoenix app with internal contexts**: less ceremony, but no compile-time enforcement of the boundary. Rejected for boundary integrity.
- **Four apps (split out `motif_rules_clue`)**: justified once a second game exists; premature now.
- **Five+ apps (split `motif_engine` further into repo/rules/server)**: defer; let actual friction motivate splits.

## Consequences
**Positive**
- The architectural diagram in ADR-0001 is mirrored in the build graph.
- Bypassing MCP from the web tier becomes a visible `mix.exs` change, not a hidden import.
- Per-app test suites; each app can be reasoned about in isolation.

**Negative**
- Slightly more boilerplate at scaffold time (three `mix.exs` files, three `application.ex` modules).
- Shared utilities require deliberate placement (in `motif_engine` if domain-y, in a future `motif_core` lib if neutral).

**Future considerations**
- Spin off `motif_rules_clue` (and `motif_rules_<other>`) into its own app once we add a second game.
- If/when we add an admin/observer tier, an `motif_admin` app may be warranted.

## References
- `doc/plan/primary-goal-prototype-and-hazy-sparrow.md` — Architecture decisions § Umbrella structure
- ADR-0001 (boundaries), ADR-0002 (Elixir/OTP)
- Mix umbrellas: https://hexdocs.pm/mix/Mix.html#module-umbrella-projects
