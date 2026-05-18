defmodule MotifMcp.Tools.MoveToRoom do
  @moduledoc """
  Submit a move-to-room intent for the calling player's character.
  Does NOT advance the turn cursor (use `end_turn` for that).
  """

  @behaviour MotifMcp.Tool

  @impl true
  def name, do: "move_to_room"

  @impl true
  def description do
    "Move your character to a room adjacent to its current room " <>
      "(through a corridor or a secret passage)."
  end

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "to_room_slug" => %{
          "type" => "string",
          "description" => "Slug of the destination room (e.g. 'study', 'library')."
        }
      },
      "required" => ["to_room_slug"]
    }
  end

  @impl true
  def handle(%{player_id: player_id, game_id: game_id}, args) do
    case args do
      %{"to_room_slug" => dest} when is_binary(dest) ->
        intent = %{type: :move_to_room, player_id: player_id, to_room_slug: dest}

        case MotifEngine.submit_intent(game_id, intent) do
          :ok -> {:ok, %{"status" => "moved", "to_room_slug" => dest}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :missing_arg_to_room_slug}
    end
  end
end
