defmodule MotifEngine.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Motif.PubSub},
      {Boltx, Application.fetch_env!(:boltx, MotifEngine.Bolt)},
      {Registry, keys: :unique, name: MotifEngine.GameRegistry},
      MotifEngine.GameSupervisor
    ]

    opts = [strategy: :one_for_one, name: MotifEngine.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
