defmodule MotifEngineTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  describe "ping/0" do
    test "round-trips a RETURN 1 query against Neo4j" do
      assert {:ok, 1} = MotifEngine.ping()
    end

    test "Motif.ping/0 facade returns the same result" do
      assert {:ok, 1} = Motif.ping()
    end
  end

  describe "start_game/2 with Clue rules" do
    setup do
      game_id = "g-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
      on_exit(fn -> cleanup(game_id) end)
      %{game_id: game_id}
    end

    test "creates a game whose graph contains the expected node counts", %{game_id: game_id} do
      players = [
        %{id: "#{game_id}/player/1", name: "Alice"},
        %{id: "#{game_id}/player/2", name: "Bob"},
        %{id: "#{game_id}/player/3", name: "Carol"}
      ]

      assert {:ok, ^game_id} =
               Motif.start_game(MotifEngine.Rules.Clue,
                 game_id: game_id,
                 players: players,
                 seed: 42
               )

      assert count_nodes(game_id, "Game") == 1
      assert count_nodes(game_id, "Player") == 3
      assert count_nodes(game_id, "Character") == 6
      assert count_nodes(game_id, "Weapon") == 6
      assert count_nodes(game_id, "Room") == 9
      assert count_nodes(game_id, "Card") == 21
    end

    test "builds a closed :NEXT ring among players", %{game_id: game_id} do
      players = [
        %{id: "#{game_id}/player/1", name: "Alice"},
        %{id: "#{game_id}/player/2", name: "Bob"},
        %{id: "#{game_id}/player/3", name: "Carol"}
      ]

      assert {:ok, ^game_id} =
               Motif.start_game(MotifEngine.Rules.Clue,
                 game_id: game_id,
                 players: players,
                 seed: 1
               )

      cypher = """
      MATCH (p:Player)-[:IN_GAME]->(g:Game {id: $id})
      MATCH (p)-[:NEXT]->(q:Player)
      RETURN count(*) AS n
      """

      assert query_one(cypher, %{id: game_id})["n"] == 3
    end

    test "the game has exactly 3 SOLUTION edges to distinct card kinds", %{game_id: game_id} do
      players = [
        %{id: "#{game_id}/player/1", name: "Alice"},
        %{id: "#{game_id}/player/2", name: "Bob"}
      ]

      assert {:ok, ^game_id} =
               Motif.start_game(MotifEngine.Rules.Clue,
                 game_id: game_id,
                 players: players,
                 seed: 7
               )

      cypher = """
      MATCH (g:Game {id: $id})-[:SOLUTION]->(c:Card)
      RETURN collect(c.kind) AS kinds
      """

      kinds = query_one(cypher, %{id: game_id})["kinds"] |> Enum.sort()
      assert kinds == ["character", "room", "weapon"]
    end
  end

  # ---- helpers ------------------------------------------------------------

  defp count_nodes(game_id, "Game") do
    query_one("MATCH (g:Game {id: $id}) RETURN count(g) AS n", %{id: game_id})["n"]
  end

  defp count_nodes(game_id, label) do
    cypher = """
    MATCH (n:#{label})-[:IN_GAME]->(g:Game {id: $id})
    RETURN count(n) AS n
    """

    query_one(cypher, %{id: game_id})["n"]
  end

  defp query_one(cypher, params) do
    {:ok, response} = Boltx.query(MotifEngine.Bolt, cypher, params)
    Boltx.Response.first(response)
  end

  defp cleanup(game_id) do
    Boltx.query!(
      MotifEngine.Bolt,
      """
      MATCH (g:Game {id: $id})
      OPTIONAL MATCH (n)-[:IN_GAME]->(g)
      DETACH DELETE g, n
      """,
      %{id: game_id}
    )
  end
end
