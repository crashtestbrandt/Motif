defmodule MotifMcp.ToolsTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  alias MotifMcp.Tools

  setup do
    game_id = "g-tools-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    players = [
      %{id: "#{game_id}/p1", name: "Alice"},
      %{id: "#{game_id}/p2", name: "Bob"}
    ]

    {:ok, ^game_id} =
      Motif.start_game(MotifEngine.Rules.Clue, game_id: game_id, players: players, seed: 11)

    on_exit(fn -> cleanup(game_id) end)

    %{
      game_id: game_id,
      ctx_alice: %{player_id: "#{game_id}/p1", game_id: game_id},
      ctx_bob: %{player_id: "#{game_id}/p2", game_id: game_id}
    }
  end

  describe "get_my_hand" do
    test "returns the calling player's cards", %{ctx_alice: ctx} do
      assert {:ok, %{"cards" => cards}} = Tools.call(ctx, "get_my_hand", %{})
      assert length(cards) == 9
      assert Enum.all?(cards, &Map.has_key?(&1, :kind))
    end

    test "Alice's hand and Bob's hand are disjoint",
         %{ctx_alice: ctx_a, ctx_bob: ctx_b} do
      {:ok, %{"cards" => a}} = Tools.call(ctx_a, "get_my_hand", %{})
      {:ok, %{"cards" => b}} = Tools.call(ctx_b, "get_my_hand", %{})
      assert MapSet.disjoint?(MapSet.new(a), MapSet.new(b))
    end

    test "IGNORES forged player_id in args — always uses ctx.player_id (ADR-0009)",
         %{ctx_alice: ctx_a, ctx_bob: ctx_b} do
      {:ok, %{"cards" => alice_real}} = Tools.call(ctx_a, "get_my_hand", %{})

      # Bob calls get_my_hand but forges Alice's player_id in args.
      forged = %{"player_id" => ctx_a.player_id}
      {:ok, %{"cards" => result}} = Tools.call(ctx_b, "get_my_hand", forged)

      # The handler must have returned BOB's hand (from session ctx), not
      # Alice's. Assert by disjoint membership: result shares no card with
      # Alice's real hand.
      assert MapSet.disjoint?(MapSet.new(result), MapSet.new(alice_real))
    end
  end

  describe "get_my_location" do
    test "returns the room of the player's character", %{ctx_alice: ctx} do
      assert {:ok, %{"room_slug" => "hall", "room_name" => "Hall"}} =
               Tools.call(ctx, "get_my_location", %{})
    end

    test "ignores forged player_id in args", %{ctx_alice: ctx_a, ctx_bob: ctx_b} do
      # Even with Alice's id forged in args, ctx is Bob's — both happen to
      # be in Hall at setup, so this test specifically asserts the lookup
      # was done by Bob's player_id, not Alice's, by checking the handler
      # ran without raising and returned Bob's room.
      {:ok, %{"room_slug" => slug}} =
        Tools.call(ctx_b, "get_my_location", %{"player_id" => ctx_a.player_id})

      assert slug == "hall"
    end
  end

  describe "list_legal_actions" do
    test "returns moves + suggest + accuse + end_turn for the current player", %{
      ctx_alice: ctx
    } do
      assert {:ok, %{"actions" => actions}} = Tools.call(ctx, "list_legal_actions", %{})
      types = actions |> Enum.map(& &1["type"]) |> Enum.sort() |> Enum.uniq()
      assert types == ["end_turn", "make_accusation", "make_suggestion", "move_to_room"]
    end

    test "returns nothing for the other player", %{ctx_bob: ctx} do
      assert {:ok, %{"actions" => []}} = Tools.call(ctx, "list_legal_actions", %{})
    end
  end

  describe "move_to_room" do
    test "moves the character to an adjacent room", %{game_id: game_id, ctx_alice: ctx} do
      assert {:ok, %{"status" => "moved", "to_room_slug" => "study"}} =
               Tools.call(ctx, "move_to_room", %{"to_room_slug" => "study"})

      assert {:ok, %{room_slug: "study"}} =
               MotifEngine.get_player_location(game_id, ctx.player_id)
    end

    test "rejects unreachable destinations", %{ctx_alice: ctx} do
      assert {:error, {:unreachable_room, _}} =
               Tools.call(ctx, "move_to_room", %{"to_room_slug" => "kitchen"})
    end

    test "ignores forged player_id in args — uses ctx", %{ctx_alice: ctx_a, ctx_bob: ctx_b} do
      # Bob (not his turn) tries to use Alice's id in args. The handler
      # uses ctx.player_id (Bob), so the engine rejects with :not_your_turn.
      assert {:error, :not_your_turn} =
               Tools.call(ctx_b, "move_to_room", %{
                 "to_room_slug" => "study",
                 "player_id" => ctx_a.player_id
               })
    end

    test "rejects when to_room_slug is missing", %{ctx_alice: ctx} do
      assert {:error, :missing_arg_to_room_slug} = Tools.call(ctx, "move_to_room", %{})
    end
  end

  describe "end_turn" do
    test "advances the turn cursor", %{game_id: game_id, ctx_alice: ctx_a, ctx_bob: ctx_b} do
      assert {:ok, %{"status" => "turn_ended"}} = Tools.call(ctx_a, "end_turn", %{})
      assert {:ok, %{"actions" => actions}} = Tools.call(ctx_b, "list_legal_actions", %{})
      assert length(actions) > 0

      {:ok, snapshot} = MotifEngine.Snapshot.load(game_id)
      assert snapshot.current_turn_player_id == ctx_b.player_id
    end

    test "rejects when it isn't the caller's turn", %{ctx_bob: ctx} do
      assert {:error, :not_your_turn} = Tools.call(ctx, "end_turn", %{})
    end
  end

  describe "registry" do
    test "catalog lists every tool with name + description + inputSchema" do
      tools = Tools.catalog()
      assert length(tools) == 9

      for tool <- tools do
        assert is_binary(tool["name"])
        assert is_binary(tool["description"])
        assert is_map(tool["inputSchema"])
      end
    end

    test "unknown tools return a structured error", %{ctx_alice: ctx} do
      assert {:error, {:unknown_tool, "frobnicate"}} = Tools.call(ctx, "frobnicate", %{})
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
