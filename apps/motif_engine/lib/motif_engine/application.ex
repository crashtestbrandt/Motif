defmodule MotifEngine.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Boltx, Application.fetch_env!(:boltx, MotifEngine.Bolt)}
    ]

    opts = [strategy: :one_for_one, name: MotifEngine.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
