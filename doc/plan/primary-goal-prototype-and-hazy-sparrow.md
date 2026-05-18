# Motif — Clue prototype plan

## Context

**Motif** is a greenfield prototype (started 2026-05-18, repo is empty save for `.git`) for a multiplayer AI-driven tabletop RPG engine. The first concrete target is the board game **Clue**; the aspirational target is any tabletop RPG by swapping a rules package.

This prototype exists to **validate four architectural assumptions before any of them gets baked in**:

1. Players interact with the engine only via an LLM (chat).
2. The LLM interacts with the engine only via **MCP** (Model Context Protocol).
3. The **Neo4j** knowledge graph is mutated only by the **rule engine** — never directly by MCP handlers or LiveView code.
4. Rules are deterministic, ideally pure, and packaged per-game. A "game" = a rules package.

A secondary purpose is for Brandt to learn idiomatic **Elixir + Cypher + Neo4j** along the way, so design choices favor idiomatic patterns over expedient ones.

**Scope (confirmed):**
- Clue with **rooms-as-graph** movement (incl. secret passages); no dice/grid.
- **2–6 human players** in their own browser sessions; no AI opponents.
- Each player's chat surface is a **Phoenix LiveView** pane driven by direct Anthropic API calls (Claude with tool use).

## Library choices

| Concern | Choice | Why |
|---|---|---|
| Neo4j driver | `boltx` | Active, supports Bolt 5.x / Neo4j 5.x. `bolt_sips` is dormant. |
| MCP | `ex_mcp` | Mature, both client + server, stdio/SSE/WebSocket transports. |
| Rule engine substrate | `gen_statem` + behaviour-dispatch | Idiomatic OTP, zero-dep, demonstrates state-machine patterns the user wants to learn. |
| HTTP / Anthropic API | `req` | Idiomatic Elixir HTTP client. |
| Persistence | Neo4j 5.x in Docker | Graph is authoritative source of truth. |

## Architecture decisions (load-bearing)

### MCP transport: SSE on `127.0.0.1`, not in-process

The whole prototype is a test of "LLM only touches engine via MCP." An in-process transport silently lets code reach across the boundary; SSE on localhost costs negligible latency at Clue scale and forces every privilege escalation to be visible on the wire. Drop to stdio later if we ever colocate.

### Rule purity: keep pure rules, Neo4j as source of truth, no event log

Rule functions are pure: `(snapshot, intent) -> {:ok, [mutations]} | {:error, reason}`. A per-game `gen_statem` is the write coordinator — it loads a snapshot, calls the pure rule, applies mutations in a single Neo4j transaction. **No caching, no event log.** At Clue scale this is microseconds; the event-log layer is a different prototype.

### Hidden-information gating: `player_id` lives in the MCP session, never in tool arguments

Bound at MCP handshake time (LiveView opens session → server stamps it with authenticated player). Tool handlers read `player_id` from session context only. If a tool's JSON schema even *accepts* a `player_id` arg, the boundary is already broken. Codify this as a `MotifMcp.Auth.calling_player(session)` helper plus a property test asserting every tool handler calls it.

### Process model: one `gen_statem` per game; graph is authoritative

`DynamicSupervisor` spawns one game process per active game, registered via `Registry` by `game_id`. **Turn order lives in the graph** as a `:NEXT` ring of `:Player` nodes plus a `:CURRENT_TURN` edge from `:Game`. The gen_statem holds no truth — only a write lock for serializing concurrent intents. Crash recovery is "reload `game_id`."

### Umbrella structure (minimal)

Three apps. Defer further splitting until the second game arrives.

```
motif/
├── apps/
│   ├── motif_engine/      # rule behaviour, gen_statem, boltx repo, Clue rules pack as a sub-module
│   ├── motif_mcp/         # ex_mcp server, session auth, tool handlers
│   └── motif_web/         # Phoenix LiveView + Anthropic client
└── mix.exs                # umbrella root
```

## Cypher schema (Clue)

**Node labels:** `:Game`, `:Player`, `:Character`, `:Room`, `:Weapon`, `:Card`, `:Suggestion`, `:Accusation`, `:Turn`.

**Relationship types:**
- `:IN_GAME` — entity belongs to a game
- `:PLAYS_AS` — Player → Character
- `:HOLDS` — Player → Card (private)
- `:LOCATED_IN` — Character → Room
- `:CONNECTS` — Room → Room (corridors)
- `:SECRET_PASSAGE` — Room → Room
- `:SOLUTION` — Game → Card (three of them, hidden)
- `:NEXT` — Player → Player (turn ring)
- `:CURRENT_TURN` — Game → Player
- `:SUGGESTED` — Suggestion → {Character, Weapon, Room}
- `:DISPROVED_BY` — Suggestion → Player
- `:REVEALED` — Suggestion → Card (private)

Indexes/constraints on entry: unique `id` on every node label; composite index on `(:Card {kind, name})`.

## MCP tools exposed to the player's LLM

| Tool | Purpose |
|---|---|
| `get_game_state` | Public board state, visible to anyone. |
| `get_my_hand` | Caller's private cards (session-scoped). |
| `get_my_location` | Caller's current room. |
| `list_legal_actions` | What the caller can do right now. |
| `move_to_room` | Move caller's character along a corridor or secret passage. |
| `make_suggestion` | Propose character + weapon in current room. |
| `respond_to_suggestion` | Disprove with a specific card (only callable by the asked player). |
| `make_accusation` | Final guess; ends game on resolve. |
| `end_turn` | Yield to next player. |
| `get_notebook` | Engine-maintained per-player deductions. |

## Build sequence (each milestone independently demoable)

1. **Skeleton + Neo4j up.** Umbrella scaffolded, Neo4j 5.x via Docker Compose, `boltx` connected, one health-check Cypher round-trip from `iex`. Demo: `iex> Motif.ping()`.
2. **Rule behaviour + Clue setup.** `MotifEngine.Rules` behaviour (`setup/1`, `legal_actions/2`, `apply_intent/3`, `view_for/2`). Clue rules pack implements `setup/1` (deal cards, place pawns, pick solution, build `:NEXT` ring). Demo: mix task creates a game; inspect graph in Neo4j Browser.
3. **gen_statem + first legal move.** Per-game process accepts a `:move_to_room` intent, applies via the pure rule, writes the mutation, advances turn cursor. Demo: iex script plays two moves alternately, observed in Neo4j Browser.
4. **MCP server with session-bound player_id.** `ex_mcp` over local SSE. Tools so far: `get_my_hand`, `get_my_location`, `list_legal_actions`, `move_to_room`, `end_turn`. Demo: small ex_mcp client script plays a turn; second session cannot read first session's hand (negative test).
5. **LiveView shell + Anthropic tool-use loop.** Each player gets a chat pane; LiveView holds the Claude conversation and forwards Claude's `tool_use` to MCP. Movement only. Demo: two browser tabs, two humans walking around the mansion via chat.
6. **Suggestion + disprove + accusation.** Full hidden-info loop. The disprove sub-turn — server needs to prompt a *specific other player's* session — will stress-test the MCP boundary; if it cannot be modeled as that player's own LLM calling `respond_to_suggestion`, see Risk 2. Demo: full game played by two humans to a win.
7. **Invariant tests + polish.** Property tests:
   - "No MCP tool handler reads `player_id` from arguments" (AST/static check).
   - "Every graph mutation in a session is preceded by a rule invocation" (telemetry trace assertion).
   - "Same intent sequence → same final graph state" (determinism check).
   Demo: green test suite + 6-player game.

## Risks the prototype must surface

1. **LLM round-trip latency.** If Claude takes seconds per turn, gameplay drags. Measure round-trip-per-turn at milestone 5. If painful, "players only interact via LLM" (assumption 1) may need a deterministic UI fallback — which is itself a finding worth recording.
2. **Server-initiated prompts for disprove.** Asking a *specific* other player to disprove requires that player's LLM to act on a server-initiated cue. If ex_mcp's notification/sampling primitives don't model this cleanly, the temptation will be server-pushed actions — which bends assumption 2. This is the single most architecturally informative milestone.
3. **Snapshot growth.** Loading the full game state every intent is fine at Clue scale; it won't scale to D&D-sized maps. Watch snapshot size growth. If it pushes us toward caches in LiveView, that threatens assumption 3.

## Critical files (to be created)

- `apps/motif_engine/lib/motif_engine/rules.ex` — rule behaviour
- `apps/motif_engine/lib/motif_engine/game_server.ex` — per-game `gen_statem`
- `apps/motif_engine/lib/motif_engine/repo.ex` — boltx wrapper
- `apps/motif_engine/lib/motif_engine/rules/clue.ex` — Clue rules pack
- `apps/motif_mcp/lib/motif_mcp/server.ex` — ex_mcp server + session auth
- `apps/motif_mcp/lib/motif_mcp/auth.ex` — `calling_player/1` trust boundary
- `apps/motif_web/lib/motif_web/live/table_live.ex` — LiveView + Anthropic tool-use loop
- `docker-compose.yml` — Neo4j 5.x for local dev
- `config/config.exs` — boltx, ex_mcp, Anthropic API key env wiring

## Verification

**End-to-end:**
- Two browser tabs, two players, start a game from milestone 5 onward. Walk through the mansion; at milestone 6, play to a win/lose accusation.
- Open Neo4j Browser and visualize `MATCH (g:Game)-[*1..2]-(n) RETURN g, n` mid-game to confirm graph state matches what each player sees.

**Hidden-info negative tests (codified, not manual):**
- A player session attempting `get_my_hand` *with* a forged `player_id` arg either rejects the arg or returns the *session's* player's hand — never the forged one.
- Inspecting Claude's transcript should never reveal another player's hand even if the prompt instructs Claude to "report all hands you can see."

**Determinism test:**
- Capture a sequence of intents from a played game; replay against a fresh database; assert resulting graph is isomorphic to the original.

**Invariant tests** (see milestone 7):
- Static check: no MCP tool handler reads `player_id` from `args`.
- Telemetry trace: every Neo4j write is preceded by a `MotifEngine.Rules.apply_intent/3` span in the same trace.

**Smoke commands:**
```bash
docker compose up -d neo4j
mix deps.get
mix test
iex -S mix
# in iex:
Motif.ping()
{:ok, game_id} = MotifEngine.start_game(player_count: 2)
mix phx.server  # then open two browser tabs at http://localhost:4000
```
