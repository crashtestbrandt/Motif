# Motif

**Motif** is a prototype for a multiplayer, AI-driven tabletop RPG engine. The first concrete target is the board game **Clue**; the aspiration is that any tabletop RPG (D&D, GURPS, Eden, etc.) can be supported by swapping a rules package.

The prototype exists to **validate four architectural assumptions** before any of them are baked in:

1. Players interact with the engine only via an LLM (chat).
2. The LLM interacts with the engine only via **MCP** (Model Context Protocol).
3. The **Neo4j** knowledge graph is mutated only by the **rule engine** — never directly by MCP handlers or web code.
4. Rules are deterministic, ideally pure, and packaged per-game. A "game" = a rules package.

A secondary goal is for the owner (Brandt) to learn idiomatic **Elixir + OTP + Cypher + Neo4j** along the way, so favor idiomatic patterns over expedient ones.

## Stack

| Layer | Choice | ADR |
|---|---|---|
| Language / runtime | Elixir on the BEAM, OTP idioms | [ADR-0002](doc/adr/ADR-0002-elixir-otp-platform.md) |
| Web tier | Phoenix LiveView; self-hosted OpenAI-compatible LLM via `req` | [ADR-0012](doc/adr/ADR-0012-phoenix-liveview-chat-surface.md), [ADR-0014](doc/adr/ADR-0014-self-hosted-llm-only.md) |
| MCP | `ex_mcp` over SSE on `127.0.0.1` | [ADR-0005](doc/adr/ADR-0005-ex-mcp-library.md), [ADR-0008](doc/adr/ADR-0008-mcp-transport-local-sse.md) |
| Rule engine | Pure rule functions + per-game `gen_statem` write coordinator; rules implement a behaviour | [ADR-0006](doc/adr/ADR-0006-rule-engine-pure-rules-and-write-coordinator.md), [ADR-0007](doc/adr/ADR-0007-rules-packaged-per-game-via-behaviour.md) |
| Storage | Neo4j 5.x via Docker, accessed through `boltx` | [ADR-0003](doc/adr/ADR-0003-neo4j-as-knowledge-graph.md), [ADR-0004](doc/adr/ADR-0004-boltx-neo4j-driver.md) |
| Project layout | Mix umbrella with three apps: `motif_engine`, `motif_mcp`, `motif_web` | [ADR-0011](doc/adr/ADR-0011-umbrella-project-layout.md) |
| Identity & trust | `player_id` bound at MCP session handshake; never a tool argument | [ADR-0009](doc/adr/ADR-0009-player-id-bound-at-mcp-session.md) |

See [`doc/adr/`](doc/adr/) for the full set of ADRs and [`doc/plan/`](doc/plan/) for active plans.

## Architecture in one diagram

```
                ┌──────────┐    chat     ┌────────────┐
   Player(s) ───┤ LiveView ├────────────▶│ Anthropic  │
                │  (web)   │◀────────────┤   API      │
                └────┬─────┘  tool_use   └────────────┘
                     │ MCP (local SSE)
                     ▼
                ┌──────────┐
                │ MCP srv  │  session-bound player_id
                │(motif_mcp)│
                └────┬─────┘
                     │ rule invocation
                     ▼
                ┌──────────┐  pure rules   ┌──────────────┐
                │ Engine   │  + write      │ Rules pack   │
                │(gen_statem│  coordinator │ (Clue, ...)  │
                │ per game)│               └──────────────┘
                └────┬─────┘
                     │ Cypher (boltx)
                     ▼
                ┌──────────┐
                │  Neo4j   │  authoritative
                │  5.x     │  source of truth
                └──────────┘
```

The arrows are directional and load-bearing — see [ADR-0001](doc/adr/ADR-0001-architectural-boundaries.md).

## Repository layout

```
motif/
├── apps/
│   ├── motif_engine/   # rule behaviour, gen_statem, boltx Repo, Clue rules
│   ├── motif_mcp/      # ex_mcp server, session auth, tool handlers
│   └── motif_web/      # Phoenix LiveView + Anthropic client
├── config/
├── doc/
│   ├── adr/            # Architecture Decision Records (this is load-bearing)
│   └── plan/           # plans for in-flight or upcoming work
├── docker-compose.yml  # Neo4j 5.x for local dev
└── mix.exs             # umbrella root
```

(Code apps will appear during milestone 1 of the build sequence; see `doc/plan/`.)

---

## Architecture Decision Records (ADRs)

ADRs live in [`doc/adr/`](doc/adr/) and follow [`doc/adr/ADR-TEMPLATE.md`](doc/adr/ADR-TEMPLATE.md). The index is at [`doc/adr/README.md`](doc/adr/README.md).

**ADRs are how this project records architecturally significant decisions.** They are not design documents, not change logs, and not status updates — they capture a single decision with enough context to be re-litigated honestly later.

### When an ADR is required

Author an ADR before merging any change that:

1. **Establishes or alters an architectural boundary** — what may call what; what owns which data; what is or isn't a trust boundary. (Anything that would amend one of the four assumptions in [ADR-0001](doc/adr/ADR-0001-architectural-boundaries.md) requires a new ADR superseding it.)
2. **Adopts or replaces a load-bearing dependency** — anything that, if it failed or was abandoned, would require non-trivial rework. New language, new database, new transport, new framework, new behaviour-defining library.
3. **Defines or changes a protocol/contract** — wire formats, behaviours, MCP tool catalogs, Cypher schema shape, snapshot shape exchanged between layers.
4. **Changes the persistence model** — what is stored where, how it's keyed, what's authoritative, whether/when caches or event logs are introduced.
5. **Introduces a security or trust mechanism** — auth, session identity, hidden-information gating, sandboxing.
6. **Sets a cross-cutting convention that future code must follow** — e.g. "all mutations must flow through `apply_intent/3`," "no tool handler reads `player_id` from args."

### When an ADR is *not* required

Don't write an ADR for:

- Implementation details that are obviously reversible (variable names, internal function shapes, file organization within a single module).
- Bug fixes that don't change a contract.
- Adding a new game's rules pack that *conforms* to the existing `MotifEngine.Rules` behaviour — the conformance is the contract; the rules themselves are content.
- Performance tweaks that don't alter the architecture (adding an index in Neo4j is content; introducing a cache layer is an ADR).
- Test infrastructure choices unless they encode a load-bearing invariant.

When in doubt: if a future contributor would be confused by *why* the code looks this way without an ADR, write one. If they'd be bored, don't.

### How to author an ADR

1. **Pick the next sequential number.** Look at [`doc/adr/README.md`](doc/adr/README.md); use `ADR-NNNN`, zero-padded to four digits.
2. **Copy the template.**
   ```bash
   cp doc/adr/ADR-TEMPLATE.md doc/adr/ADR-NNNN-<kebab-case-slug>.md
   ```
3. **Fill every section** of the template:
   - **Title** — short, descriptive; mirrors the slug.
   - **Status** — start with `Proposed — YYYY-MM-DD — Owner: <name>`. Change to `Accepted` when you (or the reviewer, when there is one) commit to the decision. Mark `Superseded by ADR-NNNN` if a later ADR replaces it.
   - **Context** — the forces and constraints that made the decision necessary. Cite incidents, plans, or related ADRs by path. Don't editorialize; describe the situation.
   - **Decision** — exactly what we chose. Include code/schema/snippets where they tighten the contract. Be unambiguous.
   - **Rationale** — *why* this choice, including at least one alternative and why it was rejected. "There were no alternatives" is almost never true and is a smell when claimed.
   - **Consequences** — positive, negative, and future considerations. State the negative consequences plainly; an ADR that has only positives is suspicious.
   - **References** — related ADRs (always link by file path), external docs, plans.
4. **Update the index.** Add a row to the table in [`doc/adr/README.md`](doc/adr/README.md).
5. **If this ADR supersedes another**, edit the older ADR's Status line to read `Superseded by ADR-NNNN` and add a forward reference in its References section. Do not edit any other section of the older ADR — it remains a record of what was decided at the time.
6. **Commit ADR + code together.** The ADR is part of the change it describes. Don't merge code that contradicts a still-Accepted ADR without first superseding it.

### Authoring style

- **Concise.** A good ADR is 1–2 screens. If you need more, it's likely two decisions.
- **One decision per ADR.** If you find yourself writing "and we also chose…" for a different concern, split.
- **State the bad parts.** Decisions have costs. If the ADR doesn't acknowledge them, the next person to hit them will think you didn't notice.
- **Cite alternatives by name.** "Considered X, rejected because Y." Bare assertions ("this is the obvious choice") age poorly.
- **Link, don't duplicate.** If two ADRs depend on each other, cross-link. Don't restate the same context twice.
- **Immutable after Accepted.** Fix typos if you must, but a substantive change is a new ADR.

### Process notes for AI agents working on this repo

When you (Claude or any AI agent) propose a change that meets the criteria above:

- Write the ADR *first*, alongside the code change, in the same patch/PR.
- If a planned change would violate an existing Accepted ADR, **stop and surface the conflict to the human owner** — don't quietly bypass the ADR.
- When in plan mode, capture the plan into [`doc/plan/`](doc/plan/) (mirroring `~/.claude/plans/`) so it is version-controlled. ADRs come out of plans; plans don't replace ADRs.
- Prefer extending an existing behaviour, schema, or pattern over introducing a new one. If a new one is justified, that's an ADR.
