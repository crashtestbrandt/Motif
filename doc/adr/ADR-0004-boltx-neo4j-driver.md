# Architecture Decision Record (ADR)

## Title
ADR-0004: `boltx` as the Elixir Neo4j driver

## Status
Accepted — 2026-05-18 — Owner: Brandt Frazier

## Context
Having chosen Neo4j (ADR-0003), we need an Elixir Bolt-protocol driver. Two candidates exist:

- **`bolt_sips`** — historically the canonical Elixir Neo4j driver. Last release April 2021; maintainer publicly sought new stewards in October 2022; effectively dormant.
- **`boltx`** — community successor. Active maintenance; supports Bolt 5.0–5.4; targets Neo4j 5.x. Recent dependency updates as of early 2026.

## Decision
Use **`boltx`** (Hex: https://hex.pm/packages/boltx, GitHub: https://github.com/sagastume/boltx) as the sole Neo4j driver.

## Rationale
- It is the only actively maintained option.
- It targets the Neo4j 5.x line we're running.
- Bolt 5.x support is required for current Cypher features and transaction semantics.

**Alternatives considered:**
- `bolt_sips`: dormant. Re-adopting it would mean either accepting unmaintained code or self-maintaining a fork — out of scope for a prototype.
- HTTP API directly via `req`: gives up the Bolt streaming/transaction model and adds wire overhead.
- `Ex4j` (a thin Ecto-flavored wrapper over `boltx`): keep on the radar but don't adopt yet — adds an abstraction layer before we know the Cypher idioms we actually want.

## Consequences
**Positive**
- Single dependency, single connection pool.
- Native transaction semantics map cleanly to the rule-engine write coordinator (ADR-0006).

**Negative**
- `boltx` is pre-1.0; API may evolve. Pin a specific version in `mix.exs` and read release notes before bumps.
- Smaller community than `bolt_sips` historically had — less Stack Overflow ammunition; expect to read source.

**Future considerations**
- If `boltx` is abandoned, alternatives are: fork it, switch to HTTP, or sidecar an officially-supported-language driver. Each would be its own ADR.

## References
- `boltx` on Hex: https://hex.pm/packages/boltx
- `bolt_sips` (for context): https://hex.pm/packages/bolt_sips
- ADR-0003 (Neo4j), ADR-0006 (rule engine integration point)
