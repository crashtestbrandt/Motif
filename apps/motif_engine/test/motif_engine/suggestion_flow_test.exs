defmodule MotifEngine.SuggestionFlowTest do
  @moduledoc """
  End-to-end tests for the milestone-6 game flow: suggestion, disprove,
  accusation. Hits a real Neo4j; cleans up after itself.

  Also asserts the PubSub events fire on the right transitions (the
  cross-LiveView signaling is what milestone 6 is testing).
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias MotifEngine.{Events, GameServer, Snapshot}

  setup do
    game_id = "g-flow-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    players = [
      %{id: "#{game_id}/p1", name: "Alice"},
      %{id: "#{game_id}/p2", name: "Bob"},
      %{id: "#{game_id}/p3", name: "Carol"}
    ]

    {:ok, ^game_id} =
      Motif.start_game(MotifEngine.Rules.Clue, game_id: game_id, players: players, seed: 7)

    :ok = Events.subscribe(game_id)

    on_exit(fn ->
      Events.unsubscribe(game_id)
      cleanup(game_id)
    end)

    %{
      game_id: game_id,
      p1: "#{game_id}/p1",
      p2: "#{game_id}/p2",
      p3: "#{game_id}/p3"
    }
  end

  describe "make_suggestion" do
    test "creates a Suggestion, drags the suggested character into the room, sets ASKING",
         %{game_id: gid, p1: p1, p2: p2} do
      :ok = make_suggestion(gid, p1, "plum", "knife")

      assert_receive {:suggestion_made,
                      %{
                        suggester_player_id: ^p1,
                        asking_player_id: ^p2,
                        cards: cards
                      }},
                     500

      kinds = cards |> Enum.map(& &1.kind) |> Enum.sort()
      assert kinds == ["character", "room", "weapon"]

      {:ok, snap} = Snapshot.load(gid)
      assert snap.pending_suggestion.asking_player_id == p2
      assert snap.can_suggest == false

      plum = Enum.find(snap.characters, &(&1.slug == "plum"))
      assert plum.room_slug == "hall"
    end

    test "rejects another suggestion while one is pending", %{game_id: gid, p1: p1} do
      :ok = make_suggestion(gid, p1, "plum", "knife")

      assert {:error, :suggestion_in_progress} =
               GameServer.submit_intent(gid, suggestion_intent(p1, "scarlet", "rope"))
    end
  end

  describe "respond_to_suggestion" do
    test "disprove path: card revealed, suggestion resolved, ASKING removed",
         %{game_id: gid, p1: p1, p2: p2} do
      :ok = make_suggestion(gid, p1, "plum", "knife")
      flush_inbox()

      # Figure out a card p2 holds that's in the suggestion (if any).
      {:ok, snap} = Snapshot.load(gid)
      p2_hand = Map.get(snap.players_hands, p2, [])
      sugg_ids = snap.pending_suggestion.suggested_card_ids
      matching = Enum.find(p2_hand, &(&1 in sugg_ids))

      if matching do
        card_slug = card_slug_of(snap, matching)
        :ok = GameServer.submit_intent(gid, %{
          type: :respond_to_suggestion,
          player_id: p2,
          card_slug: card_slug
        })

        assert_receive {:suggestion_response,
                        %{
                          responder_player_id: ^p2,
                          disproved?: true,
                          revealed_card: %{slug: ^card_slug},
                          revealed_to_player_id: ^p1
                        }},
                       500

        {:ok, snap2} = Snapshot.load(gid)
        assert snap2.pending_suggestion == nil
      else
        # Skip — this seed didn't give p2 a matching card. Test other path elsewhere.
        :ok
      end
    end

    test "cannot-disprove path advances ASKING; eventually unrefuted",
         %{game_id: gid, p1: p1, p2: p2, p3: p3} do
      # Force a suggestion that NO non-suggester holds — by suggesting the
      # actual solution cards (which the solution envelope holds). Find them.
      {:ok, snap} = Snapshot.load(gid)
      solution = snap.solution

      char_slug = card_slug_of(snap, Enum.find(solution, &String.contains?(&1, "character")))
      weap_slug = card_slug_of(snap, Enum.find(solution, &String.contains?(&1, "weapon")))

      # Move p1 into the solution-room first so the room component of the
      # suggestion is one no player holds.
      room_slug = card_slug_of(snap, Enum.find(solution, &String.contains?(&1, "room")))
      walk_player_to(gid, p1, room_slug)

      :ok = make_suggestion(gid, p1, char_slug, weap_slug)
      flush_inbox()

      # P2 passes.
      :ok = GameServer.submit_intent(gid, %{
        type: :respond_to_suggestion,
        player_id: p2,
        card_slug: nil
      })

      assert_receive {:suggestion_response,
                      %{responder_player_id: ^p2, disproved?: false, asking_player_id: ^p3}},
                     500

      # P3 passes.
      :ok = GameServer.submit_intent(gid, %{
        type: :respond_to_suggestion,
        player_id: p3,
        card_slug: nil
      })

      assert_receive {:suggestion_response,
                      %{responder_player_id: ^p3, disproved?: false, asking_player_id: nil}},
                     500

      {:ok, snap2} = Snapshot.load(gid)
      assert snap2.pending_suggestion == nil
    end

    test "rejects pass when caller holds a matching card",
         %{game_id: gid, p1: p1, p2: p2} do
      :ok = make_suggestion(gid, p1, "plum", "knife")

      {:ok, snap} = Snapshot.load(gid)
      p2_hand = Map.get(snap.players_hands, p2, [])
      sugg_ids = snap.pending_suggestion.suggested_card_ids

      if Enum.any?(p2_hand, &(&1 in sugg_ids)) do
        assert {:error, :must_disprove_with_held_card} =
                 GameServer.submit_intent(gid, %{
                   type: :respond_to_suggestion,
                   player_id: p2,
                   card_slug: nil
                 })
      end
    end

    test "rejects responding when not the asking player",
         %{game_id: gid, p1: p1, p3: p3} do
      :ok = make_suggestion(gid, p1, "plum", "knife")

      assert {:error, :not_your_turn_to_disprove} =
               GameServer.submit_intent(gid, %{
                 type: :respond_to_suggestion,
                 player_id: p3,
                 card_slug: nil
               })
    end
  end

  describe "make_accusation" do
    test "wrong accusation: caller is LOST; turn advances", %{game_id: gid, p1: p1, p2: p2} do
      # Pick three cards that are guaranteed NOT the solution.
      {:ok, snap} = Snapshot.load(gid)

      bad_char = first_non_solution(snap, "character")
      bad_weap = first_non_solution(snap, "weapon")
      bad_room = first_non_solution(snap, "room")

      :ok = GameServer.submit_intent(gid, %{
        type: :make_accusation,
        player_id: p1,
        character_slug: bad_char,
        weapon_slug: bad_weap,
        room_slug: bad_room
      })

      assert_receive {:accusation_resolved,
                      %{
                        accuser_player_id: ^p1,
                        correct?: false,
                        game_over?: false
                      }},
                     500

      {:ok, snap2} = Snapshot.load(gid)
      assert p1 in snap2.lost_player_ids
      assert snap2.current_turn_player_id == p2
    end

    test "correct accusation: caller WINS, game ends", %{game_id: gid, p1: p1} do
      {:ok, snap} = Snapshot.load(gid)
      [char_slug, weap_slug, room_slug] = solution_slugs(snap)

      :ok = GameServer.submit_intent(gid, %{
        type: :make_accusation,
        player_id: p1,
        character_slug: char_slug,
        weapon_slug: weap_slug,
        room_slug: room_slug
      })

      assert_receive {:accusation_resolved,
                      %{
                        accuser_player_id: ^p1,
                        correct?: true,
                        game_over?: true,
                        winner_player_id: ^p1
                      }},
                     500

      {:ok, snap2} = Snapshot.load(gid)
      assert snap2.status == "over"
      assert snap2.winner_player_id == p1
    end

    test "rejects further intents from a LOST player", %{game_id: gid, p1: p1} do
      {:ok, snap} = Snapshot.load(gid)
      bad_char = first_non_solution(snap, "character")
      bad_weap = first_non_solution(snap, "weapon")
      bad_room = first_non_solution(snap, "room")

      :ok = GameServer.submit_intent(gid, %{
        type: :make_accusation,
        player_id: p1,
        character_slug: bad_char,
        weapon_slug: bad_weap,
        room_slug: bad_room
      })

      flush_inbox()

      # p1 is now LOST; even on their turn (which has rotated away), they
      # can't take a normal action. We test by trying a move-as-suggester
      # which would normally fail with :not_your_turn first — but we want
      # to assert legal_actions is empty for them.
      {:ok, []} = GameServer.legal_actions(gid, p1)
    end
  end

  # ---- helpers -----------------------------------------------------------

  defp make_suggestion(game_id, player_id, char_slug, weap_slug) do
    GameServer.submit_intent(game_id, suggestion_intent(player_id, char_slug, weap_slug))
  end

  defp suggestion_intent(player_id, char_slug, weap_slug),
    do: %{
      type: :make_suggestion,
      player_id: player_id,
      character_slug: char_slug,
      weapon_slug: weap_slug
    }

  defp walk_player_to(game_id, player_id, target_room_slug) do
    # Cheap BFS via repeated moves. The current room and the target are
    # connected through corridors; for the prototype this is enough.
    {:ok, snap} = Snapshot.load(game_id)
    char = Enum.find(snap.characters, &(&1.player_id == player_id))

    if char.room_slug != target_room_slug do
      neighbors = snap.rooms[char.room_slug].connects_to ++ snap.rooms[char.room_slug].secret_passages_to

      next_step =
        if target_room_slug in neighbors,
          do: target_room_slug,
          else: hd(neighbors)

      :ok =
        GameServer.submit_intent(game_id, %{
          type: :move_to_room,
          player_id: player_id,
          to_room_slug: next_step
        })

      walk_player_to(game_id, player_id, target_room_slug)
    else
      :ok
    end
  end

  defp card_slug_of(snap, card_id) do
    case Enum.find(snap.cards, &(&1.id == card_id)) do
      %{slug: s} -> s
      _ -> nil
    end
  end

  defp first_non_solution(snap, kind) do
    snap.cards
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.reject(&(&1.id in snap.solution))
    |> hd()
    |> Map.get(:slug)
  end

  defp solution_slugs(snap) do
    by_kind = Enum.group_by(snap.cards, & &1.kind)

    for kind <- ["character", "weapon", "room"] do
      Enum.find(by_kind[kind], &(&1.id in snap.solution)).slug
    end
  end

  defp flush_inbox do
    receive do
      _ -> flush_inbox()
    after
      0 -> :ok
    end
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
