# Architecture Decision Record (ADR)

## Title
ADR-0001: Architectural boundaries — Player ↔ LLM ↔ MCP ↔ Rule Engine ↔ Knowledge Graph

## Status
Accepted — 2026-05-18 — Owner: Brandt Frazier

## Context
Motif is a prototype for a multiplayer AI-driven tabletop RPG engine. We need a clear separation of concerns between the human, the AI, the engine, the rules, and the persistent world state — and we need it from day one because every later decision is shaped by where these boundaries fall.

The first game implemented is Clue; the aspiration is that any tabletop RPG can be supported by swapping a rules package.

## Decision
The system is composed of five layers with strictly directional interaction:

```
Player ─chat─▶ LLM ─MCP─▶ Rule Engine ─mutations─▶ Knowledge Graph
                  ◀────── (reads) ◀───────────────
```

1. **Players interact with the engine only via an LLM (chat).** No direct UI controls bypass the LLM in this prototype.
2. **The LLM interacts with the engine only via MCP** (Model Context Protocol) — tools, resources, prompts. No bespoke RPC.
3. **The knowledge graph is mutated only by the rule engine.** MCP handlers and web code may read the graph but never write it.
4. **Rules are deterministic and packaged per-game.** A "game" = a rules package implementing a common behaviour.

## Rationale
- These four boundaries are the *thesis under test* in the prototype. Codifying them up front lets us learn whether they hold; tolerating exceptions silently would defeat the experiment.
- The chain enforces a single mutation path, which is the strongest available invariant for reasoning about game state and for auditing AI behaviour.
- Each boundary is independently inspectable: the MCP wire is observable; the graph is observable; rule invocations are traceable.

**Alternatives considered:**
- Direct UI ↔ engine bindings for "trivial" actions (faster UX). Rejected because it weakens assumption 1 silently.
- LLM gets direct DB credentials. Rejected: collapses two boundaries, eliminates the rule-engine choke point.

## Consequences
**Positive**
- Single mutation path → single place to enforce rule validity, log moves, and reason about determinism.
- Each layer is independently swappable (different LLM, different transport, different DB).
- Trust boundary for hidden information (e.g. private hands) is concrete and testable.

**Negative**
- LLM round-trip latency is on the critical path for every player action.
- "No direct UI" forecloses small ergonomic shortcuts; if latency becomes painful, the assumption may need a recorded amendment.

**Future considerations**
- The disprove sub-turn in Clue may push back on assumption 2 (server-initiated cues). Re-evaluate after milestone 6 of the build sequence.
- For games with large continuous state, assumption 3 may push back; partial-view loading may become necessary.

## References
- `doc/plan/primary-goal-prototype-and-hazy-sparrow.md` — originating plan
- ADR-0006 (rule engine model), ADR-0008 (MCP transport), ADR-0009 (player_id session gating), ADR-0010 (graph authority)
