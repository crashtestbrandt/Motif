defmodule Mix.Tasks.Motif.DemoMoves do
  @shortdoc "Create a 2-player Clue game and play two moves alternately"

  @moduledoc """
  Milestone-3 demo: spins up a fresh game, picks the first legal move for
  the current player, applies it, then repeats for the next player.

  Each move advances `:CURRENT_TURN` along the `:NEXT` ring. After the
  task exits, open Neo4j Browser at http://localhost:7474 and run the
  printed query to see the pawns in their new rooms.

      mix motif.demo_moves
  """

  use Mix.Task

  alias MotifEngine.{GameServer, Snapshot}

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    players = [
      %{id: "p-demo-1-alice", name: "Alice"},
      %{id: "p-demo-2-bob", name: "Bob"}
    ]

    case Motif.start_game(MotifEngine.Rules.Clue, players: players) do
      {:ok, game_id} ->
        Mix.shell().info("created game: #{game_id}")

        play_move(game_id, 1)
        play_move(game_id, 2)

        Mix.shell().info("\ninspect in Neo4j Browser (http://localhost:7474):")

        Mix.shell().info(
          "  MATCH (g:Game {id: '#{game_id}'})<-[:IN_GAME]-(c:Character)-[:LOCATED_IN]->(r:Room)\n" <>
            "  RETURN c.name, r.name"
        )

      {:error, reason} ->
        Mix.shell().error("failed to create game: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp play_move(game_id, turn_no) do
    {:ok, snapshot} = Snapshot.load(game_id)
    current_pid = snapshot.current_turn_player_id
    {:ok, [intent | _]} = GameServer.legal_actions(game_id, current_pid)

    char = Enum.find(snapshot.characters, &(&1.player_id == current_pid))

    Mix.shell().info(
      "turn #{turn_no}: #{name_of(snapshot, current_pid)} moves #{char.name} " <>
        "from #{char.room_slug} → #{intent.to_room_slug}"
    )

    :ok = GameServer.submit_intent(game_id, intent)
  end

  defp name_of(snapshot, player_id) do
    Enum.find_value(snapshot.players, "?", fn p -> if p.id == player_id, do: p.name end)
  end
end
