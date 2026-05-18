defmodule MotifEngine.Cypher.Mutation do
  @moduledoc """
  A single parameterized Cypher statement plus its parameters.

  A list of `t:t/0` values, applied in order inside a single Bolt
  transaction, expresses one complete state change. Rule functions are
  pure (ADR-0006) — they return mutations; the engine writes them.
  """

  @enforce_keys [:statement]
  defstruct statement: nil, params: %{}

  @type t :: %__MODULE__{
          statement: String.t(),
          params: map()
        }

  @spec new(String.t(), map()) :: t()
  def new(statement, params \\ %{}) when is_binary(statement) and is_map(params) do
    %__MODULE__{statement: statement, params: params}
  end
end
