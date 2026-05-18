defmodule MotifMcp.Tools.GetMyLocation do
  @moduledoc """
  Returns the room the calling player's character is currently in.
  """

  @behaviour MotifMcp.Tool

  @impl true
  def name, do: "get_my_location"

  @impl true
  def description, do: "Return the room your character is currently in."

  @impl true
  def input_schema do
    %{"type" => "object", "properties" => %{}, "required" => []}
  end

  @impl true
  def handle(%{player_id: player_id, game_id: game_id}, _args) do
    case MotifEngine.get_player_location(game_id, player_id) do
      {:ok, %{room_slug: slug, room_name: name}} ->
        {:ok, %{"room_slug" => slug, "room_name" => name}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
