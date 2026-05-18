defmodule MotifWebTest do
  use ExUnit.Case, async: true

  test "the Phoenix endpoint is configured for port 4000" do
    assert {:ok, 4000} = Keyword.fetch(MotifWeb.Endpoint.config(:http), :port)
  end
end
