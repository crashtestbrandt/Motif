defmodule MotifMcp.ErrorFormatTest do
  @moduledoc """
  The MCP server's JSON-RPC error.message field is the only place an LLM
  reads engine errors. Small models can't parse Elixir-tuple inspect
  output, so the server humanizes known engine error shapes here. This
  test pins the most important ones down so a model never sees
  `{:rpc, -32000, "must_disprove_with_held_card"}` again.
  """

  use ExUnit.Case, async: true

  alias MotifMcp.JsonRpc

  test "atom errors get translated to plain English" do
    msg = JsonRpc.format_error(:must_disprove_with_held_card)
    assert msg =~ "hold at least one"
    assert msg =~ "respond_to_suggestion"
    refute msg =~ ":rpc"
    refute msg =~ "{:"
  end

  test "not_your_turn reads naturally" do
    assert JsonRpc.format_error(:not_your_turn) == "It's not your turn right now."
  end

  test "suggestion_in_progress explains the wait" do
    assert JsonRpc.format_error(:suggestion_in_progress) =~ "wait"
  end

  test "unreachable_room tuple becomes a sentence with room names" do
    msg = JsonRpc.format_error({:unreachable_room, from: "hall", to: "kitchen"})
    assert msg =~ "Hall"
    assert msg =~ "Kitchen"
    assert msg =~ "aren't connected"
    refute msg =~ "{:"
  end

  test "unknown_room tuple becomes a sentence with the slug" do
    assert JsonRpc.format_error({:unknown_room, "atrium"}) == "There is no room called 'atrium'."
  end

  test "unknown atoms fall through with the raw snake_case (surface, don't hide)" do
    assert JsonRpc.format_error(:totally_new_error_we_havent_seen) ==
             "totally_new_error_we_havent_seen"
  end

  test "binary errors pass through humanize" do
    assert JsonRpc.format_error("game_over") == "The game is over."
  end

  test "unknown tuples still get inspect — not great, but visible (so we know to add cases)" do
    assert JsonRpc.format_error({:weird, :tuple, :nobody, :knows}) =~ "weird"
  end
end
