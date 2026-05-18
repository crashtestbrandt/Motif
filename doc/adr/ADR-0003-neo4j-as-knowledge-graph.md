# Architecture Decision Record (ADR)

## Title
ADR-0003: Neo4j as the knowledge graph store

## Status
Accepted — 2026-05-18 — Owner: Brandt Frazier

## Context
Game state for Clue (and the aspirational generic RPG) is inherently relational and topological:
- Rooms connect to other rooms (including secret passages).
- Players hold cards; cards belong to categories.
- Suggestions reference characters/weapons/rooms; disprovals reference cards revealed by players.
- Turn order is a cyclic relationship over players.

These are graph problems. Modeling them in a relational store would require either constant joins or denormalization; modeling them in a key/value or document store would scatter integrity across application code.

A secondary purpose of Motif is to learn Cypher and Neo4j patterns.

## Decision
Use **Neo4j 5.x** (running in Docker for local dev) as the authoritative store for all game state. State is modeled as labeled nodes and typed relationships, mutated via parameterized **Cypher** queries authored by the rule engine.

Node label sketch: `:Game`, `:Player`, `:Character`, `:Room`, `:Weapon`, `:Card`, `:Suggestion`, `:Accusation`.
Relationship type sketch: `:IN_GAME`, `:PLAYS_AS`, `:HOLDS`, `:LOCATED_IN`, `:CONNECTS`, `:SECRET_PASSAGE`, `:SOLUTION`, `:NEXT`, `:CURRENT_TURN`, `:SUGGESTED`, `:DISPROVED_BY`, `:REVEALED`.

## Rationale
- Room adjacency, turn-order rings, and "card revealed by player X to player Y" are first-class graph constructs.
- A single MERGE/MATCH pattern expresses things that would be a join cascade in SQL.
- The owner's learning goal makes Neo4j the natural choice over Postgres + recursive CTEs.

**Alternatives considered:**
- **PostgreSQL**: well-trod, mature; loses the learning value and makes secret-passage / turn-ring queries awkward.
- **In-memory ETS / Mnesia**: fast and idiomatic Elixir, but loses durability and a visualizable state of the world. Reconsider only if persistence proves uninteresting to the experiment.
- **Document store (e.g. Mongo)**: fits hands-of-cards but not topology.

## Consequences
**Positive**
- The game's state is inspectable and visualizable in Neo4j Browser at any moment — invaluable for prototyping.
- Cypher's pattern-matching syntax makes legality checks (e.g. "is room A reachable from room B?") legible.
- Authoritative graph + pure rules + write coordinator (ADR-0010) gives a single, traceable mutation path.

**Negative**
- Operational complexity of running a DB server alongside the BEAM app (mitigated by Docker Compose locally).
- Cypher round-trips have latency (~ms per query); not free in a tight per-intent loop.
- Less Elixir-ecosystem maturity than Postgres + Ecto.

**Future considerations**
- If snapshot-load-per-intent becomes too expensive at larger games (see Risk 3 in plan), consider partial views or replicas — but that should be its own ADR.

## References
- `doc/plan/primary-goal-prototype-and-hazy-sparrow.md` — Cypher schema sketch
- ADR-0004 (boltx driver), ADR-0010 (graph authority)
- Neo4j Bolt protocol: https://neo4j.com/docs/bolt/current/
