defmodule MotifEngine do
  @moduledoc """
  motif's rule engine and Neo4j boundary. Other apps in the umbrella
  reach the knowledge graph through this app — never directly.

  See ADR-0001 (architectural boundaries) and ADR-0010 (graph authority).
  """

  alias MotifEngine.{GameServer, GameSupervisor, Repo, Rules}

  defdelegate ping, to: Repo

  @doc """
  Initialize a new game.

  Calls the rules module's pure `setup/1`, commits the returned mutations
  in a single Bolt transaction (ADR-0006), and starts a `GameServer` for
  the new game.

  ## Options

    * `:game_id` — optional. A binary id for the game; generated if absent.
    * `:players` — required. `[%{id: ..., name: ...}, ...]`.
    * `:seed`    — optional. Integer seed for rule-pack randomness.
  """
  @spec start_game(module(), keyword()) :: {:ok, Rules.game_id()} | {:error, term()}
  def start_game(rules_module, opts) when is_atom(rules_module) and is_list(opts) do
    game_id = Keyword.get_lazy(opts, :game_id, &generate_game_id/0)
    seed = Keyword.get_lazy(opts, :seed, &generate_seed/0)
    players = Keyword.fetch!(opts, :players)

    setup_opts = [game_id: game_id, players: players, seed: seed]

    with {:ok, mutations} <- rules_module.setup(setup_opts),
         :ok <- Repo.transaction(mutations),
         {:ok, _pid} <- GameSupervisor.start_game(game_id, rules_module) do
      {:ok, game_id}
    end
  end

  @doc "Submit an intent to a running game's GameServer."
  @spec submit_intent(Rules.game_id(), map()) :: :ok | {:error, term()}
  defdelegate submit_intent(game_id, intent), to: GameServer

  @doc "Read-only: list the intents currently legal for `player_id`."
  @spec legal_actions(Rules.game_id(), Rules.player_id()) :: {:ok, [map()]} | {:error, term()}
  defdelegate legal_actions(game_id, player_id), to: GameServer

  defp generate_game_id, do: "g-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp generate_seed, do: :rand.uniform(1_000_000_000)
end
