defmodule MotifMcp.Tools.MakeAccusation do
  @moduledoc """
  Submit an accusation. If all three cards match the hidden solution
  the caller WINS. If any are wrong the caller is eliminated — they
  stay in the game to disprove other players' suggestions but can no
  longer act on their own turn.
  """

  @behaviour MotifMcp.Tool

  @impl true
  def name, do: "make_accusation"

  @impl true
  def description do
    "Make a final accusation: <character> in <room> with <weapon>. " <>
      "Correct → you win. Wrong → you're eliminated from acting, " <>
      "though your hand still disproves others' suggestions."
  end

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "character_slug" => %{"type" => "string"},
        "weapon_slug" => %{"type" => "string"},
        "room_slug" => %{"type" => "string"}
      },
      "required" => ["character_slug", "weapon_slug", "room_slug"]
    }
  end

  @impl true
  def handle(%{player_id: pid, game_id: gid}, args) do
    case args do
      %{
        "character_slug" => char,
        "weapon_slug" => weap,
        "room_slug" => room
      }
      when is_binary(char) and is_binary(weap) and is_binary(room) ->
        intent = %{
          type: :make_accusation,
          player_id: pid,
          character_slug: char,
          weapon_slug: weap,
          room_slug: room
        }

        case MotifEngine.submit_intent(gid, intent) do
          :ok -> {:ok, %{"status" => "accused"}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :missing_args}
    end
  end
end
