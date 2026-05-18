defmodule MotifMcp.Auth do
  @moduledoc """
  Token store. Each `(game_id, player_id)` pair gets a fresh opaque
  token; presenting that token at session creation seals the session's
  identity (ADR-0009).

  In milestone 4 the only issuer is server-side code (tests + the demo
  task). Milestone 5 will replace direct issuance with a Phoenix login
  flow; this module's API will not need to change.
  """

  use GenServer

  @type token :: String.t()
  @type ctx :: %{player_id: String.t(), game_id: String.t()}

  # ---- client API --------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Issue a new opaque token for `(game_id, player_id)`."
  @spec issue_token(String.t(), String.t()) :: {:ok, token()}
  def issue_token(game_id, player_id) when is_binary(game_id) and is_binary(player_id) do
    token = "tok-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    GenServer.call(__MODULE__, {:issue, token, %{game_id: game_id, player_id: player_id}})
  end

  @doc "Resolve a token to the bound identity, if any."
  @spec resolve(token()) :: {:ok, ctx()} | :error
  def resolve(token) when is_binary(token), do: GenServer.call(__MODULE__, {:resolve, token})

  @doc "Revoke a token (idempotent)."
  @spec revoke(token()) :: :ok
  def revoke(token) when is_binary(token), do: GenServer.call(__MODULE__, {:revoke, token})

  # ---- callbacks ---------------------------------------------------------

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:issue, token, ctx}, _from, state) do
    {:reply, {:ok, token}, Map.put(state, token, ctx)}
  end

  def handle_call({:resolve, token}, _from, state) do
    case Map.fetch(state, token) do
      {:ok, ctx} -> {:reply, {:ok, ctx}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:revoke, token}, _from, state) do
    {:reply, :ok, Map.delete(state, token)}
  end
end
