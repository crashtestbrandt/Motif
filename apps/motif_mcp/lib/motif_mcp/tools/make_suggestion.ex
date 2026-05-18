defmodule MotifMcp.Tools.MakeSuggestion do
  @moduledoc """
  Submit a suggestion. The room is implicit (must be the caller's
  current room). The suggested character pawn is dragged into that room
  by the engine — classic Clue mechanics.

  After the suggestion lands, every other player in the turn order is
  asked in sequence to disprove (see `respond_to_suggestion`).
  """

  @behaviour MotifMcp.Tool

  @impl true
  def name, do: "make_suggestion"

  @impl true
  def description do
    "Propose that <character> committed the murder in your current " <>
      "room with <weapon>. Other players will then be asked to disprove."
  end

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "character_slug" => %{
          "type" => "string",
          "description" => "Slug of the suggested character (e.g. 'scarlet', 'plum')."
        },
        "weapon_slug" => %{
          "type" => "string",
          "description" => "Slug of the suggested weapon (e.g. 'rope', 'wrench')."
        }
      },
      "required" => ["character_slug", "weapon_slug"]
    }
  end

  @impl true
  def handle(%{player_id: pid, game_id: gid}, args) do
    case args do
      %{"character_slug" => char, "weapon_slug" => weap}
      when is_binary(char) and is_binary(weap) ->
        intent = %{
          type: :make_suggestion,
          player_id: pid,
          character_slug: char,
          weapon_slug: weap
        }

        case MotifEngine.submit_intent(gid, intent) do
          :ok -> {:ok, %{"status" => "suggested"}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :missing_args}
    end
  end
end
