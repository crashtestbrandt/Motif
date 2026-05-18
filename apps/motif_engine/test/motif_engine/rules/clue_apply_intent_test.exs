defmodule MotifEngine.Rules.ClueApplyIntentTest do
  use ExUnit.Case, async: true

  alias MotifEngine.Cypher.Mutation
  alias MotifEngine.Rules.Clue

  # A minimal synthetic snapshot. Two players + two characters placed in
  # the Hall, plus a few rooms with adjacencies that match real Clue.
  defp snapshot do
    %{
      game_id: "g-t",
      status: "active",
      can_suggest: true,
      current_turn_player_id: "p1",
      winner_player_id: nil,
      lost_player_ids: [],
      next_player: %{"p1" => "p2", "p2" => "p1"},
      players: [
        %{id: "p1", name: "Alice"},
        %{id: "p2", name: "Bob"}
      ],
      cards: [],
      players_hands: %{"p1" => [], "p2" => []},
      solution: [],
      pending_suggestion: nil,
      characters: [
        %{
          id: "g-t/character/scarlet",
          slug: "scarlet",
          name: "Miss Scarlet",
          player_id: "p1",
          room_slug: "hall"
        },
        %{
          id: "g-t/character/mustard",
          slug: "mustard",
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
    test "produces 2 mutations for a legal corridor move (move only; turn does NOT advance)" do
      intent = %{type: :move_to_room, player_id: "p1", to_room_slug: "study"}
      assert {:ok, mutations} = Clue.apply_intent(snapshot(), intent)
      assert length(mutations) == 2
      assert Enum.all?(mutations, &match?(%Mutation{}, &1))

      [delete, create] = mutations
      assert delete.statement =~ "DELETE r"
      assert create.statement =~ "CREATE (c)-[:LOCATED_IN]->(room)"
      refute Enum.any?(mutations, &(&1.statement =~ "CURRENT_TURN"))
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

  describe "apply_intent :end_turn" do
    test "advances CURRENT_TURN and resets can_suggest" do
      intent = %{type: :end_turn, player_id: "p1"}
      assert {:ok, [advance, reset]} = Clue.apply_intent(snapshot(), intent)
      assert match?(%Mutation{}, advance)
      assert advance.statement =~ "CURRENT_TURN"
      assert reset.statement =~ "can_suggest"
    end

    test "rejects end_turn when it isn't the caller's turn" do
      intent = %{type: :end_turn, player_id: "p2"}
      assert {:error, :not_your_turn} = Clue.apply_intent(snapshot(), intent)
    end
  end

  describe "legal_actions" do
    test "current player gets moves + make_suggestion + make_accusation + end_turn" do
      actions = Clue.legal_actions(snapshot(), "p1")

      types = actions |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort()
      assert types == [:end_turn, :make_accusation, :make_suggestion, :move_to_room]

      moves = Enum.filter(actions, &(&1.type == :move_to_room))
      destinations = moves |> Enum.map(& &1.to_room_slug) |> Enum.sort()
      assert destinations == ["billiard", "lounge", "study"]
      assert Enum.all?(moves, &(&1.player_id == "p1"))
    end

    test "make_suggestion is offered only when in a room and can_suggest is true" do
      snap = %{snapshot() | can_suggest: false}
      refute Enum.any?(Clue.legal_actions(snap, "p1"), &(&1.type == :make_suggestion))
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
        snap
        |> Clue.legal_actions("p1")
        |> Enum.filter(&(&1.type == :move_to_room))
        |> Enum.map(& &1.to_room_slug)
        |> Enum.sort()

      assert destinations == ["hall", "kitchen", "library"]
    end

    test "returns [] when it's not the player's turn" do
      assert Clue.legal_actions(snapshot(), "p2") == []
    end

    test "returns [] when game is over" do
      snap = %{snapshot() | status: "over"}
      assert Clue.legal_actions(snap, "p1") == []
    end

    test "asking player gets respond_to_suggestion options" do
      # P1 (the suggester) suggested; P2 is being asked. P2 holds one matching card.
      char_card_id = "g-t/card/character/scarlet"

      snap = %{
        snapshot()
        | cards: [
            %{id: char_card_id, kind: "character", slug: "scarlet", name: "Miss Scarlet"}
          ],
          players_hands: %{"p1" => [], "p2" => [char_card_id]},
          pending_suggestion: %{
            id: "s1",
            state: "pending",
            suggester_id: "p1",
            asking_player_id: "p2",
            suggested_card_ids: [char_card_id],
            cannot_disprove_player_ids: []
          }
      }

      actions = Clue.legal_actions(snap, "p2")
      assert [%{type: :respond_to_suggestion, card_slug: "scarlet"}] = actions
    end

    test "asking player with no matching cards gets pass-only" do
      snap = %{
        snapshot()
        | cards: [
            %{
              id: "g-t/card/character/scarlet",
              kind: "character",
              slug: "scarlet",
              name: "Miss Scarlet"
            }
          ],
          players_hands: %{"p1" => [], "p2" => []},
          pending_suggestion: %{
            id: "s1",
            state: "pending",
            suggester_id: "p1",
            asking_player_id: "p2",
            suggested_card_ids: ["g-t/card/character/scarlet"],
            cannot_disprove_player_ids: []
          }
      }

      assert [%{type: :respond_to_suggestion, card_slug: nil}] = Clue.legal_actions(snap, "p2")
    end

    test "non-asking player gets nothing while a suggestion is pending" do
      snap = %{
        snapshot()
        | pending_suggestion: %{
            id: "s1",
            state: "pending",
            suggester_id: "p1",
            asking_player_id: "p2",
            suggested_card_ids: [],
            cannot_disprove_player_ids: []
          }
      }

      assert Clue.legal_actions(snap, "p1") == []
    end
  end

  defp snap_char("p1"),
    do: %{
      id: "g-t/character/scarlet",
      slug: "scarlet",
      name: "Miss Scarlet",
      player_id: "p1",
      room_slug: "hall"
    }

  defp snap_char("p2"),
    do: %{
      id: "g-t/character/mustard",
      slug: "mustard",
      name: "Colonel Mustard",
      player_id: "p2",
      room_slug: "hall"
    }
end
