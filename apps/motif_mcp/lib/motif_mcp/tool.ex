defmodule MotifMcp.Tool do
  @moduledoc """
  Behaviour every MCP tool implements.

  The handler receives a `ctx` map containing the *session-bound*
  identity — `:player_id` and `:game_id` — read from the authenticated
  MCP session at handshake time (ADR-0009). Tool handlers must read
  identity from `ctx` only. Any `player_id` / `game_id` key in `args`
  is to be ignored.
  """

  @type ctx :: %{player_id: String.t(), game_id: String.t()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback handle(ctx(), args :: map()) :: {:ok, map()} | {:error, term()}
end
