defmodule MotifEngine.Repo do
  @moduledoc """
  Thin wrapper over the boltx connection.

  This is the single seam between the engine and Neo4j. The rule engine
  (and only the rule engine) is allowed to write through this module —
  see ADR-0006 and ADR-0010.
  """

  @conn MotifEngine.Bolt

  @doc """
  Round-trip health check. Returns `{:ok, 1}` when Neo4j is reachable.
  """
  @spec ping() :: {:ok, integer()} | {:error, term()}
  def ping do
    case Boltx.query(@conn, "RETURN 1 AS n") do
      {:ok, response} ->
        case Boltx.Response.first(response) do
          %{"n" => n} -> {:ok, n}
          other -> {:error, {:unexpected_response, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
