defmodule MotifMcp.Tools do
  @moduledoc """
  Registry of MCP tools exposed to the LLM. The list is closed: any
  request for a tool not enumerated here is refused with a JSON-RPC
  "method not found" style error.
  """

  alias MotifMcp.Tool

  @tools [
    MotifMcp.Tools.GetMyHand,
    MotifMcp.Tools.GetMyLocation,
    MotifMcp.Tools.ListLegalActions,
    MotifMcp.Tools.MoveToRoom,
    MotifMcp.Tools.EndTurn
  ]

  @doc "All tool modules, in stable declaration order."
  @spec all() :: [module()]
  def all, do: @tools

  @doc "JSON-RPC-shaped catalog for `tools/list`."
  @spec catalog() :: [map()]
  def catalog do
    Enum.map(@tools, fn module ->
      %{
        "name" => module.name(),
        "description" => module.description(),
        "inputSchema" => module.input_schema()
      }
    end)
  end

  @doc """
  Dispatch a `tools/call` to the named tool. `ctx` is the session-bound
  identity; `args` is the JSON-RPC `arguments` map (string keys).
  """
  @spec call(Tool.ctx(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(ctx, name, args) when is_binary(name) and is_map(args) do
    case Enum.find(@tools, &(&1.name() == name)) do
      nil -> {:error, {:unknown_tool, name}}
      module -> module.handle(ctx, args)
    end
  end
end
