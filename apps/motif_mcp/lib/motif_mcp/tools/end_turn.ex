defmodule MotifMcp.Tools.EndTurn do
  @moduledoc """
  Yield control to the next player. Only valid for the player whose turn
  it currently is.
  """

  @behaviour MotifMcp.Tool

  @impl true
  def name, do: "end_turn"

  @impl true
  def description, do: "Yield your turn to the next player."

  @impl true
  def input_schema do
    %{"type" => "object", "properties" => %{}, "required" => []}
  end

  @impl true
  def handle(%{player_id: player_id, game_id: game_id}, _args) do
    intent = %{type: :end_turn, player_id: player_id}

    case MotifEngine.submit_intent(game_id, intent) do
      :ok -> {:ok, %{"status" => "turn_ended"}}
      {:error, reason} -> {:error, reason}
    end
  end
end
