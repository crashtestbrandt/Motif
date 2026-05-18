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

  alias MotifEngine.{Repo, Snapshot}

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
    with {:ok, snapshot} <- Snapshot.load(gid),
         {:ok, mutations} <- rm.apply_intent(snapshot, intent),
         :ok <- Repo.transaction(mutations) do
      :ok
    end
  end
end
