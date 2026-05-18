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

  @doc """
  Read-only: list the cards held by `player_id` in `game_id`. Private to
  the calling player — see ADR-0009.
  """
  @spec get_player_hand(Rules.game_id(), Rules.player_id()) ::
          {:ok, [%{kind: String.t(), name: String.t()}]} | {:error, term()}
  def get_player_hand(game_id, player_id) do
    cypher = """
    MATCH (p:Player {id: $player_id})-[:IN_GAME]->(:Game {id: $game_id})
    MATCH (p)-[:HOLDS]->(c:Card)
    RETURN c.kind AS kind, c.name AS name
    ORDER BY c.kind, c.name
    """

    case Repo.query_all(cypher, %{player_id: player_id, game_id: game_id}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &%{kind: &1["kind"], name: &1["name"]})}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Read-only: return the room the player's character is currently in.
  """
  @spec get_player_location(Rules.game_id(), Rules.player_id()) ::
          {:ok, %{room_slug: String.t(), room_name: String.t()}} | {:error, term()}
  def get_player_location(game_id, player_id) do
    cypher = """
    MATCH (p:Player {id: $player_id})-[:IN_GAME]->(:Game {id: $game_id})
    MATCH (p)-[:PLAYS_AS]->(c:Character)-[:LOCATED_IN]->(r:Room)
    RETURN r.slug AS slug, r.name AS name
    """

    case Repo.query_all(cypher, %{player_id: player_id, game_id: game_id}) do
      {:ok, [row]} -> {:ok, %{room_slug: row["slug"], room_name: row["name"]}}
      {:ok, []} -> {:error, :not_placed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_game_id, do: "g-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp generate_seed, do: :rand.uniform(1_000_000_000)
end
