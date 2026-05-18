defmodule MotifMcp.JsonRpcTest do
  use ExUnit.Case, async: true

  alias MotifMcp.JsonRpc

  @ctx %{player_id: "p-x", game_id: "g-x"}

  test "tools/list returns the catalog" do
    req = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
    resp = JsonRpc.handle(@ctx, req)

    assert resp["jsonrpc"] == "2.0"
    assert resp["id"] == 1
    assert is_list(resp["result"]["tools"])
    assert length(resp["result"]["tools"]) > 0
    assert Enum.all?(resp["result"]["tools"], &is_map_key(&1, "name"))
  end

  test "unknown method yields method-not-found error" do
    req = %{"jsonrpc" => "2.0", "id" => 2, "method" => "frobnicate"}
    resp = JsonRpc.handle(@ctx, req)
    assert resp["error"]["code"] == -32_601
    assert resp["error"]["message"] =~ "frobnicate"
    refute Map.has_key?(resp, "result")
  end

  test "malformed request (missing jsonrpc field) yields invalid-request error" do
    resp = JsonRpc.handle(@ctx, %{"id" => 3, "method" => "tools/list"})
    assert resp["error"]["code"] == -32_600
    assert resp["id"] == nil
  end

  test "tools/call missing :name yields invalid-params" do
    req = %{"jsonrpc" => "2.0", "id" => 4, "method" => "tools/call", "params" => %{}}
    resp = JsonRpc.handle(@ctx, req)
    assert resp["error"]["code"] == -32_602
  end

  test "tools/call with unknown tool yields invalid-params" do
    req = %{
      "jsonrpc" => "2.0",
      "id" => 5,
      "method" => "tools/call",
      "params" => %{"name" => "does_not_exist", "arguments" => %{}}
    }

    resp = JsonRpc.handle(@ctx, req)
    assert resp["error"]["code"] == -32_602
    assert resp["error"]["message"] =~ "does_not_exist"
  end
end
