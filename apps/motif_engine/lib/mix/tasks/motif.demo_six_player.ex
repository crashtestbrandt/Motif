defmodule Mix.Tasks.Motif.DemoSixPlayer do
  @shortdoc "Run a deterministic 6-player Clue game end-to-end"

  @moduledoc """
  Milestone-7 demo: spin up a 6-player game and drive it to completion
  via direct engine calls (no LLM in the loop). Each turn the active
  player makes a legal move, suggests something, the disprove chain
  resolves, and the turn ends. Periodic accusations force the game
  toward an end state.

  Prints the winner, eliminated players, and the printed cypher to
  inspect the final graph in Neo4j Browser.

      mix motif.demo_six_player
  """

  use Mix.Task

  alias MotifEngine.{GameServer, Snapshot}

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    game_id =
      "g-demo-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    players =
      for i <- 1..6 do
        %{id: "#{game_id}/p#{i}", name: "Player #{i}"}
      end

    {:ok, ^game_id} =
      Motif.start_game(MotifEngine.Rules.Clue,
        game_id: game_id,
        players: players,
        seed: :rand.uniform(1_000_000_000)
      )

    Mix.shell().info("created 6-player game: #{game_id}")
    Mix.shell().info("players: " <> Enum.map_join(players, ", ", & &1.name))
    Mix.shell().info("")
    Mix.shell().info("driving the game to completion...")
    Mix.shell().info("")

    final = play_until_over(game_id, 60)

    Mix.shell().info("=== game over ===")
    Mix.shell().info("winner: #{final.winner_player_id}")

    Mix.shell().info(
      "eliminated (#{length(final.lost_player_ids)}): " <>
        Enum.join(final.lost_player_ids, ", ")
    )

    Mix.shell().info("")
    Mix.shell().info("inspect: open http://localhost:7474 and run")

    Mix.shell().info(
      "    MATCH (g:Game {id: '#{game_id}'})-[*1..2]-(n) RETURN g, n"
    )
  end

  defp play_until_over(game_id, remaining) when remaining > 0 do
    {:ok, snap} = Snapshot.load(game_id)

    cond do
      snap.status == "over" ->
        snap

      snap.pending_suggestion ->
        resolve_disprove_chain(game_id)
        play_until_over(game_id, remaining - 1)

      true ->
        do_turn(game_id, snap, remaining)
        play_until_over(game_id, remaining - 1)
    end
  end

  defp play_until_over(_game_id, _),
    do: raise("game did not finish within the turn cap")

  defp do_turn(game_id, snap, remaining) do
    pid = snap.current_turn_player_id

    cond do
      pid == nil ->
        :ok

      pid in snap.lost_player_ids ->
        :ok = GameServer.submit_intent(game_id, %{type: :end_turn, player_id: pid})

      rem(remaining, 7) == 0 ->
        do_accuse(game_id, snap, pid)

      true ->
        do_move_and_suggest(game_id, pid)
    end
  end

  defp do_move_and_suggest(game_id, pid) do
    {:ok, actions} = GameServer.legal_actions(game_id, pid)
    move = Enum.find(actions, &(&1.type == :move_to_room))
    if move, do: :ok = GameServer.submit_intent(game_id, move)

    {:ok, actions2} = GameServer.legal_actions(game_id, pid)
    suggest = Enum.find(actions2, &(&1.type == :make_suggestion))

    if suggest do
      char = hd(suggest.available_character_slugs)
      weap = hd(suggest.available_weapon_slugs)

      :ok =
        GameServer.submit_intent(game_id, %{
          type: :make_suggestion,
          player_id: pid,
          character_slug: char,
          weapon_slug: weap
        })

      resolve_disprove_chain(game_id)
    end

    {:ok, latest} = Snapshot.load(game_id)

    if latest.status != "over" do
      :ok = GameServer.submit_intent(game_id, %{type: :end_turn, player_id: pid})
    end
  end

  defp do_accuse(game_id, snap, pid) do
    bad_char = first_non_solution(snap, "character")
    bad_weap = first_non_solution(snap, "weapon")
    bad_room = first_non_solution(snap, "room")

    Mix.shell().info(
      "  #{pid}: accusing #{bad_char} / #{bad_weap} / #{bad_room} (likely wrong)"
    )

    :ok =
      GameServer.submit_intent(game_id, %{
        type: :make_accusation,
        player_id: pid,
        character_slug: bad_char,
        weapon_slug: bad_weap,
        room_slug: bad_room
      })
  end

  defp resolve_disprove_chain(game_id) do
    {:ok, snap} = Snapshot.load(game_id)

    case snap.pending_suggestion do
      nil ->
        :ok

      %{asking_player_id: nil} ->
        :ok

      %{asking_player_id: pid} = sugg ->
        held = Map.get(snap.players_hands, pid, [])
        matching = Enum.find(held, &(&1 in sugg.suggested_card_ids))

        card_slug =
          case matching do
            nil -> nil
            id -> Enum.find(snap.cards, &(&1.id == id)).slug
          end

        :ok =
          GameServer.submit_intent(game_id, %{
            type: :respond_to_suggestion,
            player_id: pid,
            card_slug: card_slug
          })

        resolve_disprove_chain(game_id)
    end
  end

  defp first_non_solution(snap, kind) do
    snap.cards
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.reject(&(&1.id in snap.solution))
    |> hd()
    |> Map.get(:slug)
  end
end
