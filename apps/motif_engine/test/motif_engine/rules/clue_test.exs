defmodule MotifEngine.Rules.ClueTest do
  use ExUnit.Case, async: true

  alias MotifEngine.Cypher.Mutation
  alias MotifEngine.Rules.Clue

  @players [
    %{id: "p1", name: "Alice"},
    %{id: "p2", name: "Bob"},
    %{id: "p3", name: "Carol"}
  ]

  describe "setup/1" do
    test "is deterministic given identical opts" do
      opts = [game_id: "g-test", players: @players, seed: 12_345]
      assert {:ok, mutations1} = Clue.setup(opts)
      assert {:ok, mutations2} = Clue.setup(opts)
      assert mutations1 == mutations2
    end

    test "different seeds produce different deals" do
      opts1 = [game_id: "g-test", players: @players, seed: 1]
      opts2 = [game_id: "g-test", players: @players, seed: 2]
      assert {:ok, m1} = Clue.setup(opts1)
      assert {:ok, m2} = Clue.setup(opts2)
      refute m1 == m2
    end

    test "rejects fewer than 2 players" do
      assert {:error, {:too_few_players, 1}} =
               Clue.setup(game_id: "g", players: [hd(@players)], seed: 1)
    end

    test "rejects more than 6 players" do
      too_many =
        for i <- 1..7, do: %{id: "p#{i}", name: "P#{i}"}

      assert {:error, {:too_many_players, 7}} =
               Clue.setup(game_id: "g", players: too_many, seed: 1)
    end

    test "rejects duplicate player ids" do
      dup = [%{id: "p1", name: "A"}, %{id: "p1", name: "B"}]
      assert {:error, :duplicate_player_ids} = Clue.setup(game_id: "g", players: dup, seed: 1)
    end

    test "rejects malformed player maps" do
      bad = [%{id: "p1", name: "A"}, %{name: "no id"}]
      assert {:error, :invalid_player_shape} = Clue.setup(game_id: "g", players: bad, seed: 1)
    end

    test "errors clearly when required opts are missing" do
      assert {:error, {:missing_opt, :game_id}} = Clue.setup(players: @players, seed: 1)
      assert {:error, {:missing_opt, :players}} = Clue.setup(game_id: "g", seed: 1)
      assert {:error, {:missing_opt, :seed}} = Clue.setup(game_id: "g", players: @players)
    end

    test "produces a list of Mutation structs" do
      assert {:ok, mutations} = Clue.setup(game_id: "g-t", players: @players, seed: 42)
      assert is_list(mutations)
      assert Enum.all?(mutations, &match?(%Mutation{}, &1))
    end

    test "produces exactly 3 SOLUTION cards (one of each kind)" do
      assert {:ok, mutations} = Clue.setup(game_id: "g-t", players: @players, seed: 42)

      solution = Enum.find(mutations, fn m -> String.contains?(m.statement, "[:SOLUTION]") end)

      ids = solution.params[:ids]
      assert length(ids) == 3

      kinds = Enum.map(ids, &kind_of_card_id/1)
      assert Enum.sort(kinds) == ["character", "room", "weapon"]
    end

    test "deals all 18 non-solution cards across players" do
      assert {:ok, mutations} = Clue.setup(game_id: "g-t", players: @players, seed: 42)

      holds = Enum.find(mutations, fn m -> String.contains?(m.statement, "[:HOLDS]") end)
      deals = holds.params[:rows]

      assert length(deals) == 18
      # Round-robin among 3 players → 6 cards each
      counts = deals |> Enum.frequencies_by(& &1.player_id) |> Map.values()
      assert Enum.all?(counts, &(&1 == 6))
    end
  end

  # Card ids look like "<game_id>/card/<kind>/<slug>".
  defp kind_of_card_id(id) do
    [_game, "card", kind, _slug] = String.split(id, "/")
    kind
  end
end
