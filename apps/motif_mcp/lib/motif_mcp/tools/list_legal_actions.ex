defmodule MotifMcp.Tools.ListLegalActions do
  @moduledoc """
  Returns the actions the caller is currently allowed to take. The set
  is computed by the rule engine — never trust client-side reasoning.
  """

  @behaviour MotifMcp.Tool

  @impl true
  def name, do: "list_legal_actions"

  @impl true
  def description, do: "Return the list of actions you may legally take right now."

  @impl true
  def input_schema do
    %{"type" => "object", "properties" => %{}, "required" => []}
  end

  @impl true
  def handle(%{player_id: player_id, game_id: game_id}, _args) do
    case MotifEngine.legal_actions(game_id, player_id) do
      {:ok, actions} ->
        {:ok, %{"actions" => Enum.map(actions, &serialize/1)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp serialize(%{type: :move_to_room, to_room_slug: slug}),
    do: %{"type" => "move_to_room", "to_room_slug" => slug}

  defp serialize(%{type: :end_turn}),
    do: %{"type" => "end_turn"}

  defp serialize(%{type: :respond_to_suggestion, card_slug: slug}),
    do: %{"type" => "respond_to_suggestion", "card_slug" => slug}

  defp serialize(%{type: :make_suggestion} = intent) do
    %{
      "type" => "make_suggestion",
      "room_slug" => intent.room_slug,
      "available_character_slugs" => intent.available_character_slugs,
      "available_weapon_slugs" => intent.available_weapon_slugs
    }
  end

  defp serialize(%{type: :make_accusation} = intent) do
    %{
      "type" => "make_accusation",
      "available_character_slugs" => intent.available_character_slugs,
      "available_weapon_slugs" => intent.available_weapon_slugs,
      "available_room_slugs" => intent.available_room_slugs
    }
  end

  defp serialize(%{type: type} = intent) do
    Map.put(%{}, "type", Atom.to_string(type))
    |> Map.merge(stringify_keys(intent, [:type, :player_id]))
  end

  defp stringify_keys(map, drop) do
    map
    |> Map.drop(drop)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end
end
