defmodule MotifEngine do
  @moduledoc """
  motif's rule engine and Neo4j boundary. Other apps in the umbrella
  reach the knowledge graph through this app — never directly.

  See ADR-0001 (architectural boundaries) and ADR-0010 (graph authority).
  """

  defdelegate ping, to: MotifEngine.Repo
end
