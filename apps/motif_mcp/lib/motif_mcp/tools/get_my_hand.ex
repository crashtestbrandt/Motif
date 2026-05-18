defmodule MotifMcp.Tools.GetMyHand do
  @moduledoc """
  Returns the cards held by the *calling* player. Private; never accepts
  a `player_id` argument (ADR-0009).
  """

  @behaviour MotifMcp.Tool

  @impl true
  def name, do: "get_my_hand"

  @impl true
  def description do
    "Return the cards in your own hand. Other players' hands are not " <>
      "accessible through this tool — it always reports the caller's hand."
  end

  @impl true
  def input_schema do
    %{"type" => "object", "properties" => %{}, "required" => []}
  end

  @impl true
  def handle(%{player_id: player_id, game_id: game_id}, _args) do
    case MotifEngine.get_player_hand(game_id, player_id) do
      {:ok, cards} -> {:ok, %{"cards" => cards}}
      {:error, reason} -> {:error, reason}
    end
  end
end
