# Architecture Decision Record (ADR)

## Title
ADR-0009: `player_id` is bound at MCP session handshake, never accepted as a tool argument

## Status
Accepted — 2026-05-18 — Owner: Brandt Frazier

## Context
Clue (and most tabletop RPGs) require **hidden information**: each player has a private hand of cards; the engine must not reveal those cards to other players. The architectural assumption that "the LLM only interacts via MCP" creates a specific risk: an LLM that has been jailbroken or prompted maliciously by another player could attempt to ask the engine for *another* player's hand by passing their player_id as a tool argument.

The integrity of every hidden-info game depends on the engine refusing to honor such a request.

## Decision
**`player_id` is a property of the authenticated MCP session, not a tool argument.**

- When LiveView mounts a player's chat pane, it opens an MCP session to the engine and authenticates the session (mechanism: a session-scoped token issued by `motif_web` after Phoenix login). The MCP server stamps the session with the verified `player_id`.
- Tool JSON schemas **do not include** `player_id` fields. If a tool needs to know who's calling, it reads it from the MCP session context.
- A trust-boundary helper `MotifMcp.Auth.calling_player(session)` is the *only* sanctioned way to obtain the caller's player_id inside a tool handler.
- A property test (or AST static check) asserts that no tool handler ever reads a `player_id` from `args`. This is the single most important invariant in the prototype.

## Rationale
- An LLM-supplied argument is, by definition, untrusted input. Even with prompt engineering, you cannot rely on it.
- Session-context auth is a well-understood pattern (browser cookies, API keys per session). MCP sessions are a natural place to attach the same idea.
- Codifying the rule as both a helper *and* a test makes it cheap to enforce and hard to violate by accident.

**Alternatives considered:**
- **Accept `player_id` as a tool arg, but verify it matches the session**: still leaks the *shape* of "I could pass another player_id," and creates a per-handler verification burden that's easy to forget.
- **Encrypt/sign tool arguments client-side**: shifts trust to the LiveView code, which is still trusting the LLM that produced the args. Doesn't actually move the boundary.
- **Multiplex all players over a single MCP session**: collapses the session-as-identity model entirely. Rejected.

## Consequences
**Positive**
- Hidden information is enforceable at one well-defined choke point — the auth helper.
- The negative test is easy to write and easy to keep green.
- Future games that need additional hidden-state categories (DM-only data, faction secrets) get the same pattern.

**Negative**
- Every tool handler must remember to use the helper — but the AST test catches lapses.
- The MCP session lifecycle now has a meaningful identity attached, which the transport (ADR-0008) must preserve across reconnects.

**Future considerations**
- If the prototype needs an out-of-band admin/observer (e.g. a DM-style narrator), define a separate role on the session — *not* a "god-mode `player_id` arg."

## References
- `doc/plan/primary-goal-prototype-and-hazy-sparrow.md` — Architecture decisions § Hidden-information gating
- ADR-0001 (boundaries — this is the trust boundary), ADR-0005 (ex_mcp session model), ADR-0008 (transport carries the session)
