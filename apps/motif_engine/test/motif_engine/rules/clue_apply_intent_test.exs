defmodule MotifEngine.Rules.ClueApplyIntentTest do
  use ExUnit.Case, async: true

  alias MotifEngine.Cypher.Mutation
  alias MotifEngine.Rules.Clue

  # A minimal synthetic snapshot. Two players + two characters placed in
  # the Hall, plus a few rooms with adjacencies that match real Clue.
  defp snapshot do
    %{
      game_id: "g-t",
      current_turn_player_id: "p1",
      players: [
        %{id: "p1", name: "Alice"},
        %{id: "p2", name: "Bob"}
      ],
      characters: [
        %{
          id: "g-t/character/scarlet",
          name: "Miss Scarlet",
          player_id: "p1",
          room_slug: "hall"
        },
        %{
          id: "g-t/character/mustard",
          name: "Colonel Mustard",
          player_id: "p2",
          room_slug: "hall"
        }
      ],
      rooms: %{
        "hall" => %{
          name: "Hall",
          connects_to: ["study", "lounge", "billiard"],
          secret_passages_to: []
        },
        "study" => %{
          name: "Study",
          connects_to: ["hall", "library"],
          secret_passages_to: ["kitchen"]
        },
        "library" => %{
          name: "Library",
          connects_to: ["study", "billiard", "conservatory"],
          secret_passages_to: []
        },
        "kitchen" => %{
          name: "Kitchen",
          connects_to: ["dining", "ballroom"],
          secret_passages_to: ["study"]
        },
        "lounge" => %{
          name: "Lounge",
          connects_to: ["hall", "dining"],
          secret_passages_to: ["conservatory"]
        },
        "billiard" => %{
          name: "Billiard Room",
          connects_to: ["hall", "library", "ballroom", "dining"],
          secret_passages_to: []
        }
      }
    }
  end

  describe "apply_intent :move_to_room" do
    test "produces 3 mutations for a legal corridor move" do
      intent = %{type: :move_to_room, player_id: "p1", to_room_slug: "study"}
      assert {:ok, mutations} = Clue.apply_intent(snapshot(), intent)
      assert length(mutations) == 3
      assert Enum.all?(mutations, &match?(%Mutation{}, &1))

      [delete, create, advance] = mutations
      assert delete.statement =~ "DELETE r"
      assert create.statement =~ "CREATE (c)-[:LOCATED_IN]->(room)"
      assert advance.statement =~ "[:CURRENT_TURN]"
    end

    test "permits a secret-passage move (study → kitchen via passage)" do
      snap = put_in(snapshot().characters, [
        %{snap_char("p1") | room_slug: "study"},
        %{snap_char("p2") | room_slug: "hall"}
      ])

      intent = %{type: :move_to_room, player_id: "p1", to_room_slug: "kitchen"}
      assert {:ok, _mutations} = Clue.apply_intent(snap, intent)
    end

    test "rejects move when it's not the player's turn" do
      intent = %{type: :move_to_room, player_id: "p2", to_room_slug: "study"}
      assert {:error, :not_your_turn} = Clue.apply_intent(snapshot(), intent)
    end

    test "rejects move to a non-adjacent room" do
      intent = %{type: :move_to_room, player_id: "p1", to_room_slug: "kitchen"}
      assert {:error, {:unreachable_room, from: "hall", to: "kitchen"}} =
               Clue.apply_intent(snapshot(), intent)
    end

    test "rejects move to an unknown room" do
      intent = %{type: :move_to_room, player_id: "p1", to_room_slug: "nowhere"}
      assert {:error, {:unknown_room, "nowhere"}} = Clue.apply_intent(snapshot(), intent)
    end

    test "rejects move when the player has no character" do
      snap = put_in(snapshot().characters, [])
      intent = %{type: :move_to_room, player_id: "p1", to_room_slug: "study"}
      assert {:error, :player_has_no_character} = Clue.apply_intent(snap, intent)
    end

    test "rejects unknown intent types" do
      intent = %{type: :levitate, player_id: "p1"}
      assert {:error, {:unknown_intent, ^intent}} = Clue.apply_intent(snapshot(), intent)
    end
  end

  describe "legal_actions" do
    test "returns one move per adjacent room for the current player" do
      actions = Clue.legal_actions(snapshot(), "p1")
      destinations = actions |> Enum.map(& &1.to_room_slug) |> Enum.sort()
      assert destinations == ["billiard", "lounge", "study"]
      assert Enum.all?(actions, &(&1.type == :move_to_room))
      assert Enum.all?(actions, &(&1.player_id == "p1"))
    end

    test "returns secret-passage destinations alongside corridor ones" do
      snap = %{
        snapshot()
        | characters: [
            %{snap_char("p1") | room_slug: "study"},
            %{snap_char("p2") | room_slug: "hall"}
          ]
      }

      destinations =
        snap |> Clue.legal_actions("p1") |> Enum.map(& &1.to_room_slug) |> Enum.sort()

      assert destinations == ["hall", "kitchen", "library"]
    end

    test "returns [] when it's not the player's turn" do
      assert Clue.legal_actions(snapshot(), "p2") == []
    end

    test "returns [] when the player has no character" do
      snap = %{snapshot() | characters: []}
      assert Clue.legal_actions(snap, "p1") == []
    end
  end

  defp snap_char("p1"),
    do: %{
      id: "g-t/character/scarlet",
      name: "Miss Scarlet",
      player_id: "p1",
      room_slug: "hall"
    }

  defp snap_char("p2"),
    do: %{
      id: "g-t/character/mustard",
      name: "Colonel Mustard",
      player_id: "p2",
      room_slug: "hall"
    }
end
