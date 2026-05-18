defmodule MotifMcp.AuthTest do
  use ExUnit.Case, async: true

  alias MotifMcp.Auth

  test "issued tokens resolve back to the bound identity" do
    {:ok, token} = Auth.issue_token("g-x", "p-x")
    assert {:ok, %{game_id: "g-x", player_id: "p-x"}} = Auth.resolve(token)
  end

  test "issued tokens are opaque (do not embed the identity)" do
    {:ok, token} = Auth.issue_token("g-secret", "p-secret")
    refute token =~ "g-secret"
    refute token =~ "p-secret"
  end

  test "unknown tokens resolve to :error" do
    assert :error = Auth.resolve("tok-not-real")
  end

  test "revoke removes the binding" do
    {:ok, token} = Auth.issue_token("g-y", "p-y")
    :ok = Auth.revoke(token)
    assert :error = Auth.resolve(token)
  end
end
