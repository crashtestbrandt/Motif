defmodule MotifMcp.JsonRpc do
  @moduledoc """
  Minimal JSON-RPC 2.0 dispatcher for the MCP wire format.

  We implement the two methods needed for milestone 4:

    * `tools/list` — return the catalog.
    * `tools/call` — invoke a tool with `arguments`.

  All requests are required to be valid JSON-RPC 2.0 (jsonrpc: "2.0",
  numeric/string `id`, `method` string). Notifications (no `id`) are
  not supported in milestone 4.
  """

  alias MotifMcp.Tools

  @typep tool_ctx :: %{player_id: String.t(), game_id: String.t()}

  # Standard JSON-RPC error codes.
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @application_error -32_000

  @doc """
  Process a parsed JSON-RPC request map and return the response map
  (also a plain map; the caller is responsible for JSON encoding).
  """
  @spec handle(tool_ctx(), map()) :: map()
  def handle(ctx, %{"jsonrpc" => "2.0", "method" => method} = req) do
    id = Map.get(req, "id")
    params = Map.get(req, "params", %{})

    result =
      case method do
        "tools/list" ->
          {:ok, %{"tools" => Tools.catalog()}}

        "tools/call" ->
          dispatch_call(ctx, params)

        _ ->
          {:rpc_error, @method_not_found, "method not found: #{method}"}
      end

    finish(id, result)
  end

  def handle(_ctx, _bad) do
    finish(nil, {:rpc_error, @invalid_request, "invalid JSON-RPC 2.0 request"})
  end

  # ---- internals ---------------------------------------------------------

  defp dispatch_call(ctx, %{"name" => name} = params) do
    args = Map.get(params, "arguments", %{})

    case Tools.call(ctx, name, args) do
      {:ok, value} -> {:ok, value}
      {:error, {:unknown_tool, n}} -> {:rpc_error, @invalid_params, "unknown tool: #{n}"}
      {:error, reason} -> {:rpc_error, @application_error, format_error(reason)}
    end
  end

  defp dispatch_call(_ctx, _),
    do: {:rpc_error, @invalid_params, "tools/call requires `name` parameter"}

  defp finish(id, {:ok, value}),
    do: %{"jsonrpc" => "2.0", "id" => id, "result" => value}

  defp finish(id, {:rpc_error, code, message}),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  @doc "Build a parse-error response (used when the request body is malformed JSON)."
  @spec parse_error_response() :: map()
  def parse_error_response,
    do: %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => @parse_error, "message" => "parse error"}}
end
