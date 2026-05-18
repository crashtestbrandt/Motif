defmodule MotifMcp.Tools.RespondToSuggestion do
  @moduledoc """
  Respond to a pending suggestion. Only callable by the player the
  engine is currently asking (the `:ASKING` pointer). Either:

    * Reveal one card you hold that appears in the suggestion (the
      `card_slug` argument), or
    * Pass with `card_slug: null` — only legal if you hold *none* of
      the three suggested cards.
  """

  @behaviour MotifMcp.Tool

  @impl true
  def name, do: "respond_to_suggestion"

  @impl true
  def description do
    "Respond to the pending suggestion that names you as the next to " <>
      "disprove. Reveal one matching card from your hand, or pass if " <>
      "you hold none of the three suggested cards."
  end

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "card_slug" => %{
          "type" => ["string", "null"],
          "description" =>
            "Slug of the card you are revealing. Pass `null` only if you hold none of the suggested cards."
        }
      },
      "required" => ["card_slug"]
    }
  end

  @impl true
  def handle(%{player_id: pid, game_id: gid}, args) do
    intent = %{
      type: :respond_to_suggestion,
      player_id: pid,
      card_slug: Map.get(args, "card_slug")
    }

    case MotifEngine.submit_intent(gid, intent) do
      :ok -> {:ok, %{"status" => "responded"}}
      {:error, reason} -> {:error, reason}
    end
  end
end
