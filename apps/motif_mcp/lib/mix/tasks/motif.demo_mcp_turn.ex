defmodule Mix.Tasks.Motif.DemoMcpTurn do
  @shortdoc "End-to-end MCP turn over HTTP, including the ADR-0009 forged-arg demo"

  @moduledoc """
  Milestone-4 demo:

  1. Create a 2-player Clue game.
  2. Issue tokens for each player via `MotifMcp.Auth`.
  3. Open MCP sessions over HTTP (POST /sessions).
  4. Alice plays a full turn: list_legal_actions → move_to_room → end_turn.
  5. Bob asks for his hand.
  6. **Negative test:** Bob calls `get_my_hand` with `player_id` forged
     to Alice's id in `arguments`. The session ignores the forged value
     (ADR-0009) and Bob still sees only his own hand.

      mix motif.demo_mcp_turn
  """

  use Mix.Task

  alias MotifMcp.Auth

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:req)
    Mix.Task.run("app.start")

    players = [
      %{id: "p-demo-mcp-1", name: "Alice"},
      %{id: "p-demo-mcp-2", name: "Bob"}
    ]

    {:ok, game_id} = Motif.start_game(MotifEngine.Rules.Clue, players: players)
    Mix.shell().info("created game: #{game_id}")

    {:ok, alice_token} = Auth.issue_token(game_id, "p-demo-mcp-1")
    {:ok, bob_token} = Auth.issue_token(game_id, "p-demo-mcp-2")

    {:ok, alice} = open_session(alice_token)
    {:ok, bob} = open_session(bob_token)
    Mix.shell().info("opened sessions: alice=#{alice} bob=#{bob}\n")

    # --- Alice's full turn over MCP ---
    Mix.shell().info("=== Alice's turn (over MCP) ===")
    actions = call(alice, "list_legal_actions")["actions"]
    moves = Enum.filter(actions, &(&1["type"] == "move_to_room"))
    Mix.shell().info("  legal moves: #{inspect(Enum.map(moves, & &1["to_room_slug"]))}")

    first_move = hd(moves)

    moved =
      call(alice, "move_to_room", %{to_room_slug: first_move["to_room_slug"]})

    Mix.shell().info("  move_to_room → #{inspect(moved)}")

    ended = call(alice, "end_turn")
    Mix.shell().info("  end_turn → #{inspect(ended)}\n")

    # --- Bob's hand (legitimate) ---
    Mix.shell().info("=== Bob's hand (legitimate call) ===")
    bob_hand = call(bob, "get_my_hand")["cards"]
    Mix.shell().info("  Bob holds #{length(bob_hand)} cards")

    # --- Forged-arg negative test ---
    Mix.shell().info("\n=== ADR-0009 negative test ===")
    Mix.shell().info("  Bob calls get_my_hand with player_id=<Alice's id> in args...")
    forged = call(bob, "get_my_hand", %{player_id: "p-demo-mcp-1"})
    forged_cards = forged["cards"]

    same = MapSet.new(forged_cards) == MapSet.new(bob_hand)

    if same do
      Mix.shell().info(
        "  ✓ session ignored the forged arg — Bob still sees only his own #{length(forged_cards)} cards"
      )
    else
      Mix.shell().error(
        "  ✗ ADR-0009 VIOLATED: forged player_id changed the response — cards leaked"
      )

      exit({:shutdown, 1})
    end

    Mix.shell().info("\ngame_id: #{game_id}")

    Mix.shell().info(
      "inspect: open http://localhost:7474 and run\n" <>
        "    MATCH (g:Game {id: '#{game_id}'})-[*1..2]-(n) RETURN g, n"
    )
  end

  # ---- helpers -----------------------------------------------------------

  defp base_url, do: "http://127.0.0.1:#{Application.fetch_env!(:motif_mcp, :http_port)}"

  defp open_session(token) do
    case Req.post!(base_url() <> "/sessions", json: %{token: token}) do
      %{status: 201, body: %{"session_id" => sid}} -> {:ok, sid}
      other -> {:error, other}
    end
  end

  defp call(session_id, tool, args \\ %{}) do
    body = %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: "tools/call",
      params: %{name: tool, arguments: args}
    }

    resp = Req.post!(base_url() <> "/sessions/#{session_id}/rpc", json: body)

    case resp.body do
      %{"result" => result} -> result
      %{"error" => err} -> raise "tool call #{tool} failed: #{inspect(err)}"
    end
  end
end
