defmodule MotifWeb.LLM.Transport do
  @moduledoc "Behaviour for the LLM HTTP transport. Lets tests stub the network."

  @callback post(url :: String.t(), body :: map(), headers :: [{String.t(), String.t()}]) ::
              {:ok, %{status: integer(), body: map()}} | {:error, term()}
end
