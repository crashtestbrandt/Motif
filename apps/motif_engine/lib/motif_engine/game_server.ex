defmodule MotifEngine.GameServer do
  @moduledoc """
  One process per active game. The write coordinator (ADR-0006):

      submit_intent →  load snapshot from Neo4j
                   →  call pure `apply_intent(snapshot, intent)`
                   →  apply mutations in a Bolt transaction
                   →  reply to caller

  No game state is held in this process; the graph is authoritative
  (ADR-0010). The server exists only to serialize concurrent writes.

  Modeled as `:gen_statem` in `:state_functions` mode so future milestones
  (e.g. awaiting-disprove, game-over) can add real states without
  restructuring.
  """

  @behaviour :gen_statem

  alias MotifEngine.{Events, Repo, Snapshot}

  @registry MotifEngine.GameRegistry

  # ---- child_spec / client API -------------------------------------------

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient,
      shutdown: 5_000
    }
  end

  @doc """
  Start a game server for `game_id`. The rules module is captured at
  start time and used for every intent.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    game_id = Keyword.fetch!(opts, :game_id)
    rules_module = Keyword.fetch!(opts, :rules_module)

    :gen_statem.start_link(via(game_id), __MODULE__, {game_id, rules_module}, [])
  end

  @doc "Submit an intent. Blocks until the rule and DB write complete."
  @spec submit_intent(String.t(), map()) :: :ok | {:error, term()}
  def submit_intent(game_id, intent) do
    :gen_statem.call(via(game_id), {:submit_intent, intent})
  catch
    :exit, {:noproc, _} -> {:error, :game_not_running}
  end

  @doc "Return the list of legal intents for `player_id` in this game."
  @spec legal_actions(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def legal_actions(game_id, player_id) do
    :gen_statem.call(via(game_id), {:legal_actions, player_id})
  catch
    :exit, {:noproc, _} -> {:error, :game_not_running}
  end

  defp via(game_id), do: {:via, Registry, {@registry, game_id}}

  # ---- gen_statem callbacks ----------------------------------------------

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init({game_id, rules_module}) do
    {:ok, :ready, %{game_id: game_id, rules_module: rules_module}}
  end

  # ---- :ready state ------------------------------------------------------

  def ready({:call, from}, {:submit_intent, intent}, data) do
    reply = run_intent(data, intent)
    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  def ready({:call, from}, {:legal_actions, player_id}, data) do
    reply =
      case Snapshot.load(data.game_id) do
        {:ok, snapshot} -> {:ok, data.rules_module.legal_actions(snapshot, player_id)}
        {:error, reason} -> {:error, reason}
      end

    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  # ---- internals ---------------------------------------------------------

  defp run_intent(%{game_id: gid, rules_module: rm}, intent) do
    with {:ok, before_snap} <- Snapshot.load(gid),
         {:ok, mutations} <- apply_intent_with_telemetry(rm, before_snap, intent),
         :ok <- Repo.transaction(mutations),
         {:ok, after_snap} <- Snapshot.load(gid) do
      publish_events(gid, intent, before_snap, after_snap)
      :ok
    end
  end

  defp apply_intent_with_telemetry(rules_module, snapshot, intent) do
    metadata = %{
      game_id: snapshot.game_id,
      intent_type: Map.get(intent, :type),
      player_id: Map.get(intent, :player_id),
      rules_module: rules_module
    }

    :telemetry.span([:motif_engine, :rules, :apply_intent], metadata, fn ->
      result = rules_module.apply_intent(snapshot, intent)

      outcome =
        case result do
          {:ok, mutations} -> %{outcome: :ok, mutation_count: length(mutations)}
          {:error, reason} -> %{outcome: :error, reason: reason}
        end

      {result, Map.merge(metadata, outcome)}
    end)
  end

  # ---- event derivation --------------------------------------------------

  defp publish_events(game_id, %{type: :make_suggestion}, _before, after_snap) do
    case after_snap.pending_suggestion do
      %{
        id: sid,
        suggester_id: suggester,
        asking_player_id: asking,
        suggested_card_ids: card_ids
      } ->
        cards = Enum.filter(after_snap.cards, &(&1.id in card_ids))

        Events.publish(
          game_id,
          {:suggestion_made,
           %{
             suggestion_id: sid,
             suggester_player_id: suggester,
             asking_player_id: asking,
             cards: Enum.map(cards, &Map.take(&1, [:kind, :name, :slug]))
           }}
        )

      _ ->
        :ok
    end
  end

  defp publish_events(game_id, %{type: :respond_to_suggestion}, before_snap, after_snap) do
    before_sugg = before_snap.pending_suggestion

    case {before_sugg, after_snap.pending_suggestion} do
      {nil, _} ->
        :ok

      {%{id: sid, suggester_id: suggester_id} = before, nil} ->
        # Suggestion just resolved (either disproved or unrefuted).
        revealed = load_revealed(sid)

        Events.publish(
          game_id,
          {:suggestion_response,
           %{
             suggestion_id: sid,
             responder_player_id: before.asking_player_id,
             disproved?: revealed != nil,
             asking_player_id: nil,
             revealed_card: revealed,
             # Only the suggester learns the specific card.
             revealed_to_player_id: if(revealed, do: suggester_id, else: nil)
           }}
        )

      {%{id: sid}, %{asking_player_id: next_asking} = after_p} when sid == after_p.id ->
        # cannot_disprove path that didn't end the chain.
        Events.publish(
          game_id,
          {:suggestion_response,
           %{
             suggestion_id: sid,
             responder_player_id: before_sugg.asking_player_id,
             disproved?: false,
             asking_player_id: next_asking,
             revealed_card: nil,
             revealed_to_player_id: nil
           }}
        )

      _ ->
        :ok
    end
  end

  defp publish_events(game_id, %{type: :make_accusation, player_id: pid}, _before, after_snap) do
    correct? = after_snap.winner_player_id == pid
    game_over? = after_snap.status == "over"

    Events.publish(
      game_id,
      {:accusation_resolved,
       %{
         accuser_player_id: pid,
         correct?: correct?,
         game_over?: game_over?,
         winner_player_id: after_snap.winner_player_id
       }}
    )
  end

  defp publish_events(_game_id, _intent, _before, _after), do: :ok

  defp load_revealed(suggestion_id) do
    cypher = """
    MATCH (s:Suggestion {id: $sid})-[:REVEALED]->(c:Card)
    RETURN c.slug AS slug, c.name AS name
    LIMIT 1
    """

    case Repo.query_all(cypher, %{sid: suggestion_id}) do
      {:ok, [%{"slug" => slug, "name" => name}]} -> %{slug: slug, name: name}
      _ -> nil
    end
  end
end
