defmodule MotifMcp.SessionManagerTest do
  use ExUnit.Case, async: true

  alias MotifMcp.{Auth, SessionManager}

  test "open binds identity from the token and returns a fresh session id" do
    {:ok, token} = Auth.issue_token("g-1", "p-1")
    assert {:ok, "ses-" <> _ = sid, %{game_id: "g-1", player_id: "p-1"}} = SessionManager.open(token)
    assert {:ok, %{game_id: "g-1", player_id: "p-1"}} = SessionManager.lookup(sid)
  end

  test "two opens from the same token produce different session ids" do
    {:ok, token} = Auth.issue_token("g-2", "p-2")
    {:ok, sid_a, _} = SessionManager.open(token)
    {:ok, sid_b, _} = SessionManager.open(token)
    refute sid_a == sid_b
  end

  test "open with a bogus token errors out" do
    assert {:error, :invalid_token} = SessionManager.open("tok-nope")
  end

  test "close removes the session" do
    {:ok, token} = Auth.issue_token("g-3", "p-3")
    {:ok, sid, _} = SessionManager.open(token)
    :ok = SessionManager.close(sid)
    assert :error = SessionManager.lookup(sid)
  end
end
