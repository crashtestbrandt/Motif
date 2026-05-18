defmodule MotifMcpTest do
  use ExUnit.Case, async: true
  doctest MotifMcp

  test "facade delegates issue_token to MotifMcp.Auth" do
    assert {:ok, "tok-" <> _} = MotifMcp.issue_token("g-x", "p-x")
  end
end
