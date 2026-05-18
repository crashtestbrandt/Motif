defmodule MotifEngine.Events do
  @moduledoc """
  Cross-process pub/sub for in-game events.

  Used by the LiveView chat surface (`motif_web`) to learn when a
  suggestion has been made, when a player is being asked to disprove,
  when an accusation resolves, and when the game ends — so it can nudge
  the right player's session into action without the engine pushing
  anything across the MCP boundary (ADR-0001 assumption 2).

  The PubSub server is named `Motif.PubSub` and is supervised inside
  `motif_engine`.
  """

  @pubsub Motif.PubSub

  @typedoc "Topic per game."
  @type topic :: String.t()

  @typedoc """
  All game-event message shapes published on this bus. Pattern-match on
  the tag.
  """
  @type event ::
          {:suggestion_made,
           %{
             suggestion_id: String.t(),
             suggester_player_id: String.t(),
             asking_player_id: String.t() | nil,
             cards: [%{kind: String.t(), name: String.t(), slug: String.t()}]
           }}
          | {:suggestion_response,
             %{
               suggestion_id: String.t(),
               responder_player_id: String.t(),
               disproved?: boolean(),
               asking_player_id: String.t() | nil,
               # `revealed_to_player_id` is the only session that should learn the
               # specific card; broadcast carries it so the receiver can ignore
               # the field when it doesn't match its own player_id.
               revealed_card: %{slug: String.t(), name: String.t()} | nil,
               revealed_to_player_id: String.t() | nil
             }}
          | {:accusation_resolved,
             %{
               accuser_player_id: String.t(),
               correct?: boolean(),
               game_over?: boolean(),
               winner_player_id: String.t() | nil
             }}

  @spec topic(String.t()) :: topic()
  def topic(game_id) when is_binary(game_id), do: "game:#{game_id}"

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(game_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(game_id))

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(game_id), do: Phoenix.PubSub.unsubscribe(@pubsub, topic(game_id))

  @spec publish(String.t(), event()) :: :ok
  def publish(game_id, event), do: Phoenix.PubSub.broadcast(@pubsub, topic(game_id), event)
end
