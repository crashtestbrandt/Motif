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
          status: String.t(),
          can_suggest: boolean(),
          current_turn_player_id: String.t() | nil,
          winner_player_id: String.t() | nil,
          players: [%{id: String.t(), name: String.t()}],
          lost_player_ids: [String.t()],
          next_player: %{String.t() => String.t()},
          characters: list(),
          rooms: map(),
          cards: list(),
          players_hands: %{String.t() => [String.t()]},
          solution: [String.t()],
          pending_suggestion: nil | map()
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
         {:ok, rooms} <- load_rooms(game_id),
         {:ok, cards} <- load_cards(game_id),
         {:ok, hands} <- load_hands(game_id),
         {:ok, solution} <- load_solution(game_id),
         {:ok, next_player} <- load_next_ring(game_id),
         {:ok, lost} <- load_lost(game_id),
         {:ok, pending} <- load_pending_suggestion(game_id),
         {:ok, counts} <- load_counts(game_id) do
      {:ok,
       %{
         game_id: head.game_id,
         status: head.status,
         can_suggest: head.can_suggest,
         current_turn_player_id: head.current_turn_player_id,
         winner_player_id: head.winner_player_id,
         players: players,
         lost_player_ids: lost,
         next_player: next_player,
         characters: characters,
         rooms: rooms,
         cards: cards,
         players_hands: hands,
         solution: solution,
         pending_suggestion: pending,
         suggestion_count: counts.suggestion_count,
         accusation_count: counts.accusation_count
       }}
    end
  end

  # ------------------------------------------------------------------------

  defp load_head(game_id) do
    cypher = """
    MATCH (g:Game {id: $id})
    OPTIONAL MATCH (g)-[:CURRENT_TURN]->(turn:Player)
    OPTIONAL MATCH (g)-[:WON]->(winner:Player)
    RETURN g.id AS game_id,
           coalesce(g.status, 'active') AS status,
           coalesce(g.can_suggest, true) AS can_suggest,
           turn.id AS current_turn_player_id,
           winner.id AS winner_player_id
    """

    case Repo.query_all(cypher, %{id: game_id}) do
      {:ok, [row]} ->
        {:ok,
         %{
           game_id: row["game_id"],
           status: row["status"],
           can_suggest: row["can_suggest"],
           current_turn_player_id: row["current_turn_player_id"],
           winner_player_id: row["winner_player_id"]
         }}

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
    RETURN c.id AS id, c.slug AS slug, c.name AS name, p.id AS player_id, r.slug AS room_slug
    """

    with {:ok, rows} <- Repo.query_all(cypher, %{id: game_id}) do
      {:ok,
       Enum.map(rows, fn r ->
         %{
           id: r["id"],
           slug: r["slug"],
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

  defp load_cards(game_id) do
    cypher = """
    MATCH (c:Card)-[:IN_GAME]->(g:Game {id: $id})
    RETURN c.id AS id, c.kind AS kind, c.slug AS slug, c.name AS name
    """

    with {:ok, rows} <- Repo.query_all(cypher, %{id: game_id}) do
      {:ok,
       Enum.map(rows, fn r ->
         %{id: r["id"], kind: r["kind"], slug: r["slug"], name: r["name"]}
       end)}
    end
  end

  defp load_hands(game_id) do
    cypher = """
    MATCH (p:Player)-[:IN_GAME]->(g:Game {id: $id})
    MATCH (p)-[:HOLDS]->(c:Card)
    RETURN p.id AS pid, c.id AS cid
    """

    with {:ok, rows} <- Repo.query_all(cypher, %{id: game_id}) do
      {:ok,
       rows
       |> Enum.group_by(& &1["pid"], & &1["cid"])}
    end
  end

  defp load_solution(game_id) do
    cypher = """
    MATCH (g:Game {id: $id})-[:SOLUTION]->(c:Card)
    RETURN c.id AS id
    """

    with {:ok, rows} <- Repo.query_all(cypher, %{id: game_id}) do
      {:ok, Enum.map(rows, & &1["id"])}
    end
  end

  defp load_next_ring(game_id) do
    cypher = """
    MATCH (a:Player)-[:IN_GAME]->(g:Game {id: $id})
    MATCH (a)-[:NEXT]->(b:Player)
    RETURN a.id AS from_id, b.id AS to_id
    """

    with {:ok, rows} <- Repo.query_all(cypher, %{id: game_id}) do
      {:ok, Map.new(rows, fn r -> {r["from_id"], r["to_id"]} end)}
    end
  end

  defp load_lost(game_id) do
    cypher = """
    MATCH (p:Player)-[:LOST]->(:Game {id: $id})
    RETURN p.id AS id
    """

    with {:ok, rows} <- Repo.query_all(cypher, %{id: game_id}) do
      {:ok, Enum.map(rows, & &1["id"])}
    end
  end

  defp load_counts(game_id) do
    cypher = """
    MATCH (g:Game {id: $id})
    OPTIONAL MATCH (s:Suggestion)-[:IN_GAME]->(g)
    WITH g, count(s) AS suggestion_count
    OPTIONAL MATCH (a:Accusation)-[:IN_GAME]->(g)
    RETURN suggestion_count, count(a) AS accusation_count
    """

    with {:ok, [row]} <- Repo.query_all(cypher, %{id: game_id}) do
      {:ok,
       %{
         suggestion_count: row["suggestion_count"],
         accusation_count: row["accusation_count"]
       }}
    end
  end

  defp load_pending_suggestion(game_id) do
    # A pending suggestion has an :ASKING edge to some player. Once a
    # suggestion is resolved (disproved or unrefuted) the :ASKING edge
    # is removed, so this query also implicitly filters by state.
    cypher = """
    MATCH (s:Suggestion)-[:IN_GAME]->(g:Game {id: $id})
    OPTIONAL MATCH (s)-[:ASKING]->(asking:Player)
    WITH s, asking WHERE asking IS NOT NULL
    MATCH (s)-[:MADE_BY]->(suggester:Player)
    OPTIONAL MATCH (s)-[:SUGGESTED]->(card:Card)
    WITH s, asking, suggester, collect(DISTINCT card.id) AS suggested_card_ids
    OPTIONAL MATCH (s)-[:CANNOT_DISPROVE]->(no:Player)
    RETURN s.id AS id, s.state AS state,
           suggester.id AS suggester_id,
           asking.id AS asking_player_id,
           suggested_card_ids,
           collect(DISTINCT no.id) AS cannot_disprove_player_ids
    """

    with {:ok, rows} <- Repo.query_all(cypher, %{id: game_id}) do
      case rows do
        [] ->
          {:ok, nil}

        [row] ->
          {:ok,
           %{
             id: row["id"],
             state: row["state"],
             suggester_id: row["suggester_id"],
             asking_player_id: row["asking_player_id"],
             suggested_card_ids: row["suggested_card_ids"],
             cannot_disprove_player_ids: row["cannot_disprove_player_ids"]
           }}

        many ->
          # Should never happen — at most one pending suggestion at a time.
          {:error, {:multiple_pending_suggestions, length(many)}}
      end
    end
  end
end
