defmodule MotifMcp.HttpIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias MotifMcp.Auth

  setup do
    game_id = "g-http-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    players = [
      %{id: "#{game_id}/p1", name: "Alice"},
      %{id: "#{game_id}/p2", name: "Bob"}
    ]

    {:ok, ^game_id} =
      Motif.start_game(MotifEngine.Rules.Clue, game_id: game_id, players: players, seed: 13)

    {:ok, alice_token} = Auth.issue_token(game_id, "#{game_id}/p1")
    {:ok, bob_token} = Auth.issue_token(game_id, "#{game_id}/p2")

    {:ok, alice_session} = open_session(alice_token)
    {:ok, bob_session} = open_session(bob_token)

    on_exit(fn -> cleanup(game_id) end)

    %{
      game_id: game_id,
      alice_session: alice_session,
      bob_session: bob_session,
      alice_id: "#{game_id}/p1",
      bob_id: "#{game_id}/p2"
    }
  end

  describe "session lifecycle" do
    test "POST /sessions with invalid token returns 401" do
      resp = Req.post!(base_url() <> "/sessions", json: %{token: "tok-fake"})
      assert resp.status == 401
      assert resp.body["error"] == "invalid_token"
    end

    test "POST /sessions/:id/rpc with unknown session returns 404" do
      resp =
        Req.post!(base_url() <> "/sessions/ses-fake/rpc",
          json: %{jsonrpc: "2.0", id: 1, method: "tools/list"}
        )

      assert resp.status == 404
      assert resp.body["error"] == "session_not_found"
    end
  end

  describe "tools/list" do
    test "returns the full 5-tool catalog", %{alice_session: sid} do
      resp = rpc(sid, "tools/list")
      assert resp["jsonrpc"] == "2.0"
      assert length(resp["result"]["tools"]) == 5

      names = Enum.map(resp["result"]["tools"], & &1["name"])
      assert "get_my_hand" in names
      assert "move_to_room" in names
      assert "end_turn" in names
    end

    test "no tool's input_schema accepts a player_id property (architectural invariant)",
         %{alice_session: sid} do
      resp = rpc(sid, "tools/list")

      for tool <- resp["result"]["tools"] do
        props = get_in(tool, ["inputSchema", "properties"]) || %{}
        refute Map.has_key?(props, "player_id"),
               "tool '#{tool["name"]}' advertises a `player_id` property — ADR-0009 violation"
      end
    end
  end

  describe "tools/call get_my_hand" do
    test "returns the calling session's hand", %{alice_session: sid} do
      resp = rpc(sid, "tools/call", %{name: "get_my_hand", arguments: %{}})
      cards = resp["result"]["cards"]
      assert is_list(cards)
      assert length(cards) == 9
    end

    test "two different sessions get different hands",
         %{alice_session: a, bob_session: b} do
      a_cards = rpc(a, "tools/call", %{name: "get_my_hand", arguments: %{}})["result"]["cards"]
      b_cards = rpc(b, "tools/call", %{name: "get_my_hand", arguments: %{}})["result"]["cards"]
      assert MapSet.disjoint?(MapSet.new(a_cards), MapSet.new(b_cards))
    end

    test "forged player_id in args is IGNORED — caller still sees only their own hand",
         %{alice_session: a, bob_session: b, alice_id: alice_id} do
      a_cards = rpc(a, "tools/call", %{name: "get_my_hand", arguments: %{}})["result"]["cards"]
      forged = rpc(b, "tools/call", %{name: "get_my_hand", arguments: %{player_id: alice_id}})

      forged_cards = forged["result"]["cards"]
      assert MapSet.disjoint?(MapSet.new(forged_cards), MapSet.new(a_cards)),
             "ADR-0009 violation: forging player_id in args leaked another player's hand"
    end
  end

  describe "a full turn over the wire" do
    test "list_legal_actions → move_to_room → end_turn rotates the cursor",
         %{game_id: game_id, alice_session: a, bob_session: b, bob_id: bob_id} do
      list = rpc(a, "tools/call", %{name: "list_legal_actions", arguments: %{}})
      moves = Enum.filter(list["result"]["actions"], &(&1["type"] == "move_to_room"))
      assert length(moves) > 0

      first_move = hd(moves)

      moved =
        rpc(a, "tools/call", %{
          name: "move_to_room",
          arguments: %{to_room_slug: first_move["to_room_slug"]}
        })

      assert moved["result"]["status"] == "moved"

      ended = rpc(a, "tools/call", %{name: "end_turn", arguments: %{}})
      assert ended["result"]["status"] == "turn_ended"

      # Bob now has legal actions.
      list_b = rpc(b, "tools/call", %{name: "list_legal_actions", arguments: %{}})
      assert length(list_b["result"]["actions"]) > 0

      {:ok, snap} = MotifEngine.Snapshot.load(game_id)
      assert snap.current_turn_player_id == bob_id
    end
  end

  # ---- helpers -----------------------------------------------------------

  defp base_url, do: "http://127.0.0.1:#{Application.fetch_env!(:motif_mcp, :http_port)}"

  defp open_session(token) do
    case Req.post!(base_url() <> "/sessions", json: %{token: token}) do
      %{status: 201, body: %{"session_id" => sid}} -> {:ok, sid}
      other -> {:error, other}
    end
  end

  defp rpc(sid, method, params \\ %{}) do
    body = %{jsonrpc: "2.0", id: System.unique_integer([:positive]), method: method, params: params}
    Req.post!(base_url() <> "/sessions/#{sid}/rpc", json: body).body
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
