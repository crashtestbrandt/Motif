defmodule MotifWeb do
  @moduledoc """
  motif_web — Phoenix LiveView chat surface for players (ADR-0012).

  Each player session is a LiveView process that talks to a
  self-hosted, OpenAI-compatible LLM (ADR-0014) via `MotifWeb.LLM` and
  forwards the model's tool calls to the engine through the MCP wire
  (`MotifWeb.McpClient`, ADR-0013).
  """

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {MotifWeb.Layouts, :app}
      import Phoenix.HTML
      alias Phoenix.LiveView.JS
    end
  end

  def component do
    quote do
      use Phoenix.Component
      import Phoenix.HTML
    end
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json], layouts: [html: MotifWeb.Layouts]
      import Plug.Conn
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
