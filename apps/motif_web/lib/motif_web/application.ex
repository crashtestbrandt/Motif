defmodule MotifWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: MotifWeb.PubSub},
      MotifWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MotifWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MotifWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
