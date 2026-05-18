defmodule MotifMcp.SessionManager do
  @moduledoc """
  Tracks active MCP sessions. A session is created when a client presents
  a valid token; the session's identity (`player_id`, `game_id`) is stamped
  at that moment and never read from request bodies thereafter (ADR-0009).
  """

  use GenServer

  alias MotifMcp.Auth

  @type session_id :: String.t()

  # ---- client API --------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Open a session by presenting a token. Returns the new session id and
  the bound identity; the token itself remains valid for additional
  sessions until revoked.
  """
  @spec open(Auth.token()) :: {:ok, session_id(), Auth.ctx()} | {:error, :invalid_token}
  def open(token) when is_binary(token) do
    case Auth.resolve(token) do
      {:ok, ctx} ->
        session_id = "ses-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
        :ok = GenServer.call(__MODULE__, {:put, session_id, ctx})
        {:ok, session_id, ctx}

      :error ->
        {:error, :invalid_token}
    end
  end

  @doc "Look up the identity bound to a session."
  @spec lookup(session_id()) :: {:ok, Auth.ctx()} | :error
  def lookup(session_id) when is_binary(session_id),
    do: GenServer.call(__MODULE__, {:lookup, session_id})

  @doc "Close a session (idempotent)."
  @spec close(session_id()) :: :ok
  def close(session_id) when is_binary(session_id),
    do: GenServer.call(__MODULE__, {:close, session_id})

  # ---- callbacks ---------------------------------------------------------

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:put, sid, ctx}, _from, state), do: {:reply, :ok, Map.put(state, sid, ctx)}

  def handle_call({:lookup, sid}, _from, state) do
    case Map.fetch(state, sid) do
      {:ok, ctx} -> {:reply, {:ok, ctx}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:close, sid}, _from, state), do: {:reply, :ok, Map.delete(state, sid)}
end
