defmodule Mix.Tasks.Motif.DemoChat do
  @shortdoc "Spin up a 2-player Clue game and print the LiveView URLs"

  @moduledoc """
  Milestone-5 demo:

  1. Create a 2-player Clue game.
  2. Print one LiveView URL per player.
  3. Open each URL in its own browser tab — each tab talks to a
     self-hosted LLM (ADR-0014) which calls MCP tools to read game
     state and submit moves (ADR-0001).

  Prerequisites:
    - A self-hosted, OpenAI-compatible inference server running locally.
      Dev default is LM Studio at http://127.0.0.1:1234/v1.
    - A loaded model that does tool-calling reasonably well
      (Qwen 2.5 32B+ or larger recommended).

  Override the endpoint at runtime if you're not on the LM Studio
  default:

      LLM_BASE_URL=http://127.0.0.1:8000/v1 LLM_MODEL=qwen2.5-32b-instruct \\
        iex -S mix
      iex> Mix.Task.run("motif.demo_chat")

  Leave the BEAM running afterwards — the demo task only prints URLs;
  the BEAM is what serves the chat.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    players = [
      %{id: "p-chat-1-alice", name: "Alice"},
      %{id: "p-chat-2-bob", name: "Bob"}
    ]

    case Motif.start_game(MotifEngine.Rules.Clue, players: players) do
      {:ok, game_id} ->
        Mix.shell().info("created game: #{game_id}")
        Mix.shell().info("")
        Mix.shell().info("Open in two browser tabs:")

        for p <- players do
          Mix.shell().info("  #{p.name}: http://localhost:4000/play/#{game_id}/#{p.id}")
        end

        Mix.shell().info("")
        Mix.shell().info("Then leave the BEAM running. To keep the server alive run via")
        Mix.shell().info("    iex -S mix")
        Mix.shell().info("and call Mix.Task.run(\"motif.demo_chat\") from iex,")
        Mix.shell().info("or run `mix phx.server`-style with `mix run --no-halt` afterwards.")
        Mix.shell().info("")
        Mix.shell().info("inspect: open http://localhost:7474 (Neo4j Browser) and run")

        Mix.shell().info(
          "    MATCH (g:Game {id: '#{game_id}'})-[*1..2]-(n) RETURN g, n"
        )

      {:error, reason} ->
        Mix.shell().error("failed to create game: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
