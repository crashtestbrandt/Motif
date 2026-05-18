defmodule MotifMcp do
  @moduledoc """
  motif's MCP-compatible HTTP+JSON-RPC server (ADR-0013).

  Boundary between the LLM and the engine (ADR-0001). Every tool call
  comes in over the wire, is authenticated against a session-bound
  identity (ADR-0009), and is dispatched to a `MotifMcp.Tools.*` module
  whose handler reaches the engine via `MotifEngine` only.
  """

  defdelegate issue_token(game_id, player_id), to: MotifMcp.Auth
end
