defmodule MotifEngine.Repo do
  @moduledoc """
  Thin wrapper over the boltx connection.

  This is the single seam between the engine and Neo4j. The rule engine
  (and only the rule engine) is allowed to write through this module —
  see ADR-0006 and ADR-0010.
  """

  alias MotifEngine.Cypher.Mutation

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

  @doc """
  Apply a list of mutations in a single Bolt transaction. All or nothing.

  This is the *only* sanctioned write path — the rule engine produces
  mutations; this function commits them.
  """
  @spec transaction([Mutation.t()]) :: :ok | {:error, term()}
  def transaction(mutations) when is_list(mutations) do
    result =
      Boltx.transaction(@conn, fn conn ->
        Enum.each(mutations, fn %Mutation{statement: stmt, params: params} ->
          Boltx.query!(conn, stmt, params)
        end)

        :ok
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
