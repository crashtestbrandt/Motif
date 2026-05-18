defmodule MotifMcp.Tools.ListRecentSuggestions do
  @moduledoc """
  Read the suggestion history for the game, filtered by caller
  visibility (ADR-0009). The `revealed_card` field appears only on
  suggestions you either made or disproved — never on others'.
  """

  @behaviour MotifMcp.Tool

  @impl true
  def name, do: "list_recent_suggestions"

  @impl true
  def description do
    "Return every suggestion made so far in this game. " <>
      "Each entry reports the suggester, the suggested cards, the responder " <>
      "(if disproven), and the players who said 'cannot disprove'. " <>
      "The specific card revealed in a disproof is visible only to the " <>
      "suggester and the responder."
  end

  @impl true
  def input_schema do
    %{"type" => "object", "properties" => %{}, "required" => []}
  end

  @impl true
  def handle(%{player_id: pid, game_id: gid}, _args) do
    case MotifEngine.get_recent_suggestions(gid, pid) do
      {:ok, suggestions} -> {:ok, %{"suggestions" => suggestions}}
      {:error, reason} -> {:error, reason}
    end
  end
end
