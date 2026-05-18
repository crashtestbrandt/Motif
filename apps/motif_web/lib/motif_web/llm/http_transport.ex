defmodule MotifWeb.LLM.HttpTransport do
  @moduledoc "Live HTTP transport over `Req`. The default."

  @behaviour MotifWeb.LLM.Transport

  @impl true
  def post(url, body, headers) do
    case Req.post(url, json: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %Req.Response{status: status, body: resp}} -> {:ok, %{status: status, body: resp}}
      {:error, reason} -> {:error, reason}
    end
  end
end
