defmodule MotifMcp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MotifMcp.Auth,
      MotifMcp.SessionManager,
      {Bandit, plug: MotifMcp.Router, ip: http_ip(), port: http_port()}
    ]

    opts = [strategy: :one_for_one, name: MotifMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp http_ip, do: Application.get_env(:motif_mcp, :http_ip, {127, 0, 0, 1})
  defp http_port, do: Application.get_env(:motif_mcp, :http_port, 4001)
end
