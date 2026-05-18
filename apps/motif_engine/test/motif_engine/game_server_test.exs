defmodule MotifEngine.GameServerTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  alias MotifEngine.{GameServer, Snapshot}

  setup do
    game_id = "g-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    on_exit(fn -> cleanup(game_id) end)

    players = [
      %{id: "#{game_id}/player/1", name: "Alice"},
      %{id: "#{game_id}/player/2", name: "Bob"}
    ]

    {:ok, ^game_id} =
      Motif.start_game(MotifEngine.Rules.Clue,
        game_id: game_id,
        players: players,
        seed: 1
      )

    %{game_id: game_id, players: players}
  end

  describe "submit_intent :move_to_room" do
    test "moves the character WITHOUT advancing the turn cursor",
         %{game_id: game_id, players: [p1, _p2]} do
      {:ok, snap0} = Snapshot.load(game_id)
      assert snap0.current_turn_player_id == p1.id

      char1 = Enum.find(snap0.characters, &(&1.player_id == p1.id))
      assert char1.room_slug == "hall"

      move = first_move_intent(game_id, p1.id)
      assert :ok = GameServer.submit_intent(game_id, move)

      {:ok, snap1} = Snapshot.load(game_id)
      # Still p1's turn — moves alone don't advance the cursor.
      assert snap1.current_turn_player_id == p1.id

      char1_after = Enum.find(snap1.characters, &(&1.player_id == p1.id))
      assert char1_after.room_slug == move.to_room_slug
    end

    test "rejects moves when it isn't the caller's turn",
         %{game_id: game_id, players: [_p1, p2]} do
      bogus = %{type: :move_to_room, player_id: p2.id, to_room_slug: "study"}
      assert {:error, :not_your_turn} = GameServer.submit_intent(game_id, bogus)
    end

    test "rejects moves to non-adjacent rooms",
         %{game_id: game_id, players: [p1, _p2]} do
      illegal = %{type: :move_to_room, player_id: p1.id, to_room_slug: "kitchen"}

      assert {:error, {:unreachable_room, from: "hall", to: "kitchen"}} =
               GameServer.submit_intent(game_id, illegal)
    end
  end

  describe "submit_intent :end_turn" do
    test "advances the cursor to the next player",
         %{game_id: game_id, players: [p1, p2]} do
      assert :ok = GameServer.submit_intent(game_id, %{type: :end_turn, player_id: p1.id})

      {:ok, snap1} = Snapshot.load(game_id)
      assert snap1.current_turn_player_id == p2.id
    end

    test "rejects end_turn when it isn't the caller's turn",
         %{game_id: game_id, players: [_p1, p2]} do
      assert {:error, :not_your_turn} =
               GameServer.submit_intent(game_id, %{type: :end_turn, player_id: p2.id})
    end

    test "two end_turns rotate the ring back to p1",
         %{game_id: game_id, players: [p1, p2]} do
      :ok = GameServer.submit_intent(game_id, %{type: :end_turn, player_id: p1.id})

      {:ok, snap1} = Snapshot.load(game_id)
      assert snap1.current_turn_player_id == p2.id

      :ok = GameServer.submit_intent(game_id, %{type: :end_turn, player_id: p2.id})

      {:ok, snap2} = Snapshot.load(game_id)
      assert snap2.current_turn_player_id == p1.id
    end

    test "Motif facade also works", %{game_id: game_id, players: [p1, _p2]} do
      assert :ok = Motif.submit_intent(game_id, %{type: :end_turn, player_id: p1.id})
    end
  end

  describe "when no server is running" do
    test "submit_intent returns :game_not_running" do
      bogus_id = "g-does-not-exist"
      intent = %{type: :move_to_room, player_id: "p1", to_room_slug: "study"}
      assert {:error, :game_not_running} = GameServer.submit_intent(bogus_id, intent)
    end

    test "legal_actions returns :game_not_running" do
      assert {:error, :game_not_running} = GameServer.legal_actions("g-does-not-exist", "p1")
    end
  end

  defp first_move_intent(game_id, player_id) do
    {:ok, actions} = GameServer.legal_actions(game_id, player_id)
    Enum.find(actions, &(&1.type == :move_to_room))
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
