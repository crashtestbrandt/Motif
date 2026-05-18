defmodule MotifEngine.Snapshot do
  @moduledoc """
  Loads the read-only view of game state that rule functions consume.

  The snapshot shape is intentionally *not* part of the `MotifEngine.Rules`
  behaviour — it's the engine's own internal interchange format. Rule packs
  read from it; the engine produces it. As games grow, the shape grows.

  See ADR-0006 (rule engine), ADR-0010 (graph is authoritative).
  """

  alias MotifEngine.Repo

  @type t :: %{
          game_id: String.t(),
          current_turn_player_id: String.t(),
          players: [%{id: String.t(), name: String.t()}],
          characters: [
            %{
              id: String.t(),
              name: String.t(),
              player_id: String.t() | nil,
              room_slug: String.t() | nil
            }
          ],
          rooms: %{
            String.t() => %{
              name: String.t(),
              connects_to: [String.t()],
              secret_passages_to: [String.t()]
            }
          }
        }

  @doc """
  Load the snapshot for a game. Returns `{:error, :not_found}` if the
  game does not exist.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(game_id) when is_binary(game_id) do
    with {:ok, head} <- load_head(game_id),
         {:ok, players} <- load_players(game_id),
         {:ok, characters} <- load_characters(game_id),
         {:ok, rooms} <- load_rooms(game_id) do
      {:ok,
       %{
         game_id: head.game_id,
         current_turn_player_id: head.current_turn_player_id,
         players: players,
         characters: characters,
         rooms: rooms
       }}
    end
  end

  # ------------------------------------------------------------------------

  defp load_head(game_id) do
    cypher = """
    MATCH (g:Game {id: $id})-[:CURRENT_TURN]->(p:Player)
    RETURN g.id AS game_id, p.id AS current_turn_player_id
    """

    case Repo.query_all(cypher, %{id: game_id}) do
      {:ok, [row]} ->
        {:ok, %{game_id: row["game_id"], current_turn_player_id: row["current_turn_player_id"]}}

      {:ok, []} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_players(game_id) do
    cypher = """
    MATCH (p:Player)-[:IN_GAME]->(g:Game {id: $id})
    RETURN p.id AS id, p.name AS name
    """

    with {:ok, rows} <- Repo.query_all(cypher, %{id: game_id}) do
      {:ok, Enum.map(rows, &%{id: &1["id"], name: &1["name"]})}
    end
  end

  defp load_characters(game_id) do
    cypher = """
    MATCH (c:Character)-[:IN_GAME]->(g:Game {id: $id})
    OPTIONAL MATCH (p:Player)-[:PLAYS_AS]->(c)
    OPTIONAL MATCH (c)-[:LOCATED_IN]->(r:Room)
    RETURN c.id AS id, c.name AS name, p.id AS player_id, r.slug AS room_slug
    """

    with {:ok, rows} <- Repo.query_all(cypher, %{id: game_id}) do
      {:ok,
       Enum.map(rows, fn r ->
         %{
           id: r["id"],
           name: r["name"],
           player_id: r["player_id"],
           room_slug: r["room_slug"]
         }
       end)}
    end
  end

  defp load_rooms(game_id) do
    cypher = """
    MATCH (r:Room)-[:IN_GAME]->(g:Game {id: $id})
    OPTIONAL MATCH (r)-[:CONNECTS]-(c:Room)
    WITH r, collect(DISTINCT c.slug) AS connects_to
    OPTIONAL MATCH (r)-[:SECRET_PASSAGE]-(s:Room)
    RETURN r.slug AS slug,
           r.name AS name,
           connects_to,
           collect(DISTINCT s.slug) AS secret_passages_to
    """

    with {:ok, rows} <- Repo.query_all(cypher, %{id: game_id}) do
      map =
        Map.new(rows, fn r ->
          {r["slug"],
           %{
             name: r["name"],
             connects_to: r["connects_to"],
             secret_passages_to: r["secret_passages_to"]
           }}
        end)

      {:ok, map}
    end
  end
end
