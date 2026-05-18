defmodule MotifWebTest do
  use ExUnit.Case
  doctest MotifWeb

  test "greets the world" do
    assert MotifWeb.hello() == :world
  end
end
