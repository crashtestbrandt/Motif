defmodule MotifEngine.Rules do
  @moduledoc """
  The behaviour every game's rules package implements. See ADR-0007.

  Implementations are pure: same inputs → same outputs, no I/O, no time, no
  randomness except through an explicit seed. The engine (ADR-0006) loads
  snapshots from the graph, calls these callbacks, and applies the returned
  mutations transactionally.
  """

  alias MotifEngine.Cypher.Mutation

  @type game_id :: String.t()
  @type player_id :: String.t()
  @type player :: %{required(:id) => player_id(), required(:name) => String.t()}
  @type snapshot :: map()
  @type intent :: map()

  @typedoc """
  Options accepted by `c:setup/1`. At minimum:
    * `:game_id` — caller-supplied id for the new game
    * `:players` — list of player maps (`%{id: ..., name: ...}`)
    * `:seed`    — integer seed for any randomness the rules need
  """
  @type setup_opts :: keyword()

  @doc """
  Produce the mutations that initialize a fresh game.

  Pure. Given identical `opts`, must return identical mutations.
  """
  @callback setup(setup_opts()) :: {:ok, [Mutation.t()]} | {:error, term()}

  @doc """
  Enumerate the intents the given player is currently allowed to issue.

  Pure projection of the snapshot — never returns a mutation.
  """
  @callback legal_actions(snapshot(), player_id()) :: [intent()]

  @doc """
  Validate an intent against the snapshot and produce the resulting mutations.

  Pure. Returns `{:error, reason}` for illegal intents rather than raising.
  """
  @callback apply_intent(snapshot(), intent()) :: {:ok, [Mutation.t()]} | {:error, term()}

  @doc """
  Produce the player-facing view of the snapshot — exactly what that player
  is permitted to see. Used by MCP read-tools (ADR-0009).
  """
  @callback view_for(snapshot(), player_id()) :: map()
end
