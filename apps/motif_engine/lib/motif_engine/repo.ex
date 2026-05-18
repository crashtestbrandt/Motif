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
  Run a read-only Cypher query and return all result rows as a list of maps
  (column name → value).
  """
  @spec query_all(String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def query_all(statement, params \\ %{}) when is_binary(statement) and is_map(params) do
    case Boltx.query(@conn, statement, params) do
      {:ok, response} -> {:ok, response.results}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Apply a list of mutations in a single Bolt transaction. All or nothing.

  This is the *only* sanctioned write path — the rule engine produces
  mutations; this function commits them.
  """
  @spec transaction([Mutation.t()]) :: :ok | {:error, term()}
  def transaction(mutations) when is_list(mutations) do
    metadata = %{mutation_count: length(mutations)}

    :telemetry.span([:motif_engine, :repo, :transaction], metadata, fn ->
      result =
        Boltx.transaction(@conn, fn conn ->
          Enum.each(mutations, fn %Mutation{statement: stmt, params: params} ->
            Boltx.query!(conn, stmt, params)
          end)

          :ok
        end)

      reply =
        case result do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {reply, metadata}
    end)
  end
end
