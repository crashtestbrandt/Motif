defmodule MotifWeb.McpClient do
  @moduledoc """
  Thin client for the motif_mcp HTTP+JSON-RPC server (ADR-0013).

  LiveView is the MCP *client* on behalf of the LLM: when the model
  emits a tool call, LiveView translates it to `tools/call` through
  this module. The wire boundary is concrete (HTTP) even on a single
  node — ADR-0008.
  """

  @doc "Open an MCP session by presenting a token. Returns the session id."
  @spec open_session(String.t()) :: {:ok, String.t()} | {:error, term()}
  def open_session(token) when is_binary(token) do
    case Req.post(base_url() <> "/sessions", json: %{token: token}) do
      {:ok, %{status: 201, body: %{"session_id" => sid}}} -> {:ok, sid}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "List the tool catalog. Returns the raw list of tool descriptors."
  @spec list_tools(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(session_id) when is_binary(session_id) do
    case rpc(session_id, "tools/list", %{}) do
      {:ok, %{"tools" => tools}} -> {:ok, tools}
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Invoke a tool. `args` is the JSON-RPC `arguments` map (string keys)."
  @spec call_tool(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call_tool(session_id, tool_name, args) when is_binary(session_id) and is_binary(tool_name) do
    rpc(session_id, "tools/call", %{name: tool_name, arguments: args})
  end

  # ---- internals ---------------------------------------------------------

  defp rpc(session_id, method, params) do
    body = %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive, :monotonic]),
      method: method,
      params: params
    }

    case Req.post(base_url() <> "/sessions/#{session_id}/rpc", json: body) do
      {:ok, %{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %{status: 200, body: %{"error" => err}}} ->
        {:error, {:rpc, err["code"], err["message"]}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp base_url, do: Application.fetch_env!(:motif_web, :mcp_base_url)
end
