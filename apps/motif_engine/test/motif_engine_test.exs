defmodule MotifEngineTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  describe "ping/0" do
    test "round-trips a RETURN 1 query against Neo4j" do
      assert {:ok, 1} = MotifEngine.ping()
    end

    test "Motif.ping/0 facade returns the same result" do
      assert {:ok, 1} = Motif.ping()
    end
  end
end
