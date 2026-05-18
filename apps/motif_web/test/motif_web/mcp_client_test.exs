defmodule MotifWeb.McpClientTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias MotifMcp.Auth
  alias MotifWeb.McpClient

  setup do
    game_id = "g-mcpc-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    players = [
      %{id: "#{game_id}/p1", name: "Alice"},
      %{id: "#{game_id}/p2", name: "Bob"}
    ]

    {:ok, ^game_id} =
      Motif.start_game(MotifEngine.Rules.Clue, game_id: game_id, players: players, seed: 1)

    {:ok, token} = Auth.issue_token(game_id, "#{game_id}/p1")
    on_exit(fn -> cleanup(game_id) end)

    %{game_id: game_id, token: token, player_id: "#{game_id}/p1"}
  end

  test "open_session returns a session id", %{token: token} do
    assert {:ok, "ses-" <> _} = McpClient.open_session(token)
  end

  test "open_session with a bogus token errors out" do
    assert {:error, {:http, 401, _}} = McpClient.open_session("tok-bogus")
  end

  test "list_tools returns the catalog", %{token: token} do
    {:ok, sid} = McpClient.open_session(token)
    {:ok, tools} = McpClient.list_tools(sid)
    names = Enum.map(tools, & &1["name"])
    assert "get_my_hand" in names
    assert "move_to_room" in names
    assert "end_turn" in names
  end

  test "call_tool returns the engine's response", %{token: token} do
    {:ok, sid} = McpClient.open_session(token)

    {:ok, %{"cards" => cards}} = McpClient.call_tool(sid, "get_my_hand", %{})
    assert is_list(cards)
    assert length(cards) == 9
  end

  test "call_tool surfaces JSON-RPC errors", %{token: token} do
    {:ok, sid} = McpClient.open_session(token)

    assert {:error, {:rpc, _code, msg}} = McpClient.call_tool(sid, "frobnicate", %{})
    assert msg =~ "frobnicate"
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
