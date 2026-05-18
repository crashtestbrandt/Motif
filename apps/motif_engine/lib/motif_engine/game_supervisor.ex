defmodule MotifEngine.GameSupervisor do
  @moduledoc """
  Dynamic supervisor for per-game `MotifEngine.GameServer` processes.
  One child per active game; restarts are transient (a server that exits
  cleanly is not restarted — the underlying graph state is still there
  and a future call can start a fresh server).
  """

  use DynamicSupervisor

  alias MotifEngine.GameServer

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a `GameServer` under this supervisor. Returns `{:ok, pid}` even if
  the server is already running (the existing pid is returned).
  """
  @spec start_game(String.t(), module()) :: {:ok, pid()} | {:error, term()}
  def start_game(game_id, rules_module) do
    spec = {GameServer, game_id: game_id, rules_module: rules_module}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end
end
