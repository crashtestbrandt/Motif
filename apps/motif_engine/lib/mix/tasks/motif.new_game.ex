defmodule Mix.Tasks.Motif.NewGame do
  @shortdoc "Create a new Clue game in the local Neo4j"

  @moduledoc """
  Creates a fresh Clue game and prints its `game_id`.

  ## Usage

      mix motif.new_game alice bob              # 2 players
      mix motif.new_game alice bob carol dave   # 4 players

  Requires Neo4j to be running (`docker compose up -d`).
  After running, open http://localhost:7474 and try:

      MATCH (g:Game {id: '<the-printed-id>'})-[*1..2]-(n) RETURN g, n
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    case args do
      [] ->
        Mix.shell().error("usage: mix motif.new_game <name1> <name2> [<name3> ...]")
        exit({:shutdown, 1})

      names ->
        Mix.Task.run("app.start")

        players =
          names
          |> Enum.with_index(1)
          |> Enum.map(fn {name, idx} ->
            %{id: "p-#{idx}-#{slugify(name)}", name: name}
          end)

        case Motif.start_game(MotifEngine.Rules.Clue, players: players) do
          {:ok, game_id} ->
            Mix.shell().info("created game: #{game_id}")
            Mix.shell().info("players: #{Enum.map_join(players, ", ", & &1.name)}")
            Mix.shell().info("inspect: open http://localhost:7474")
            Mix.shell().info("        MATCH (g:Game {id: '#{game_id}'})-[*1..2]-(n) RETURN g, n")

          {:error, reason} ->
            Mix.shell().error("failed to create game: #{inspect(reason)}")
            exit({:shutdown, 1})
        end
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
