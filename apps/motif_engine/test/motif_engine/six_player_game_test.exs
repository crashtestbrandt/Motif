defmodule MotifEngine.SixPlayerGameTest do
  @moduledoc """
  Milestone-7 capstone: a deterministic 6-player Clue session runs to
  completion (someone wins or all-but-one are eliminated) without
  crashes, with the engine remaining the only writer.

  This is not an LLM-driven test — we drive the engine directly to
  exercise the full rule machinery at maximum player count.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias MotifEngine.{GameServer, Snapshot}

  @game_id "g-six"
  @seed 2026

  @players for i <- 1..6,
               do: %{id: "#{@game_id}/p#{i}", name: "Player #{i}"}

  setup do
    cleanup(@game_id)
    on_exit(fn -> cleanup(@game_id) end)
    :ok
  end

  test "6 players can play to a conclusion" do
    game_id = @game_id

    {:ok, ^game_id} =
      Motif.start_game(MotifEngine.Rules.Clue,
        game_id: game_id,
        players: @players,
        seed: @seed
      )

    {:ok, snap} = Snapshot.load(@game_id)

    # Sanity: deck dealt out, 6 characters assigned.
    assert length(snap.players) == 6
    assert Enum.count(snap.characters, &(&1.player_id != nil)) == 6

    # Each player should hold 3 cards (18 dealt / 6 players).
    for p <- @players do
      hand = Map.get(snap.players_hands, p.id, [])
      assert length(hand) == 3
    end

    # Now play until the game ends or we hit the safety cap.
    final = play_until_over(@game_id, 60)

    assert final.status == "over", "game did not finish within the turn cap"
    assert final.winner_player_id != nil, "game ended without a winner"

    losers = final.lost_player_ids
    assert length(losers) <= 5, "more than 5 losers somehow"

    IO.puts(
      "  ✓ 6-player game complete — winner: #{final.winner_player_id}, " <>
        "losers: #{length(losers)}"
    )
  end

  # ---- driver ------------------------------------------------------------

  # Each turn: the current player makes its first legal move, ends turn
  # if no suggestion happened. If a suggestion is pending, walk the
  # disprove chain until resolved. Roughly once every few turns, the
  # current player makes a (likely-wrong) accusation to force progress
  # toward an end-of-game state.
  defp play_until_over(game_id, remaining_turns) when remaining_turns > 0 do
    {:ok, snap} = Snapshot.load(game_id)

    if snap.status == "over" do
      snap
    else
      cond do
        snap.pending_suggestion ->
          resolve_disprove_chain(game_id)
          play_until_over(game_id, remaining_turns - 1)

        true ->
          do_turn(game_id, snap, remaining_turns)
          play_until_over(game_id, remaining_turns - 1)
      end
    end
  end

  defp play_until_over(_game_id, _), do: raise("turn cap exceeded")

  defp do_turn(game_id, snap, remaining_turns) do
    pid = snap.current_turn_player_id

    if pid == nil or pid in snap.lost_player_ids do
      :ok = GameServer.submit_intent(game_id, %{type: :end_turn, player_id: pid})
    else
      # Decide between accusation and normal play based on remaining
      # turns — bias toward making accusations as we approach the cap
      # so the game ends.
      if rem(remaining_turns, 7) == 0 do
        do_accuse(game_id, snap, pid)
      else
        do_move_and_suggest(game_id, snap, pid)
      end
    end
  end

  defp do_move_and_suggest(game_id, _snap, pid) do
    {:ok, actions} = GameServer.legal_actions(game_id, pid)
    move = Enum.find(actions, &(&1.type == :move_to_room))

    if move do
      :ok = GameServer.submit_intent(game_id, move)
    end

    # Pull fresh actions in the new room and try a suggestion.
    {:ok, actions2} = GameServer.legal_actions(game_id, pid)
    suggest = Enum.find(actions2, &(&1.type == :make_suggestion))

    if suggest do
      char_slug = hd(suggest.available_character_slugs)
      weap_slug = hd(suggest.available_weapon_slugs)

      :ok =
        GameServer.submit_intent(game_id, %{
          type: :make_suggestion,
          player_id: pid,
          character_slug: char_slug,
          weapon_slug: weap_slug
        })

      resolve_disprove_chain(game_id)
    end

    {:ok, latest} = Snapshot.load(game_id)

    if latest.status != "over" do
      :ok = GameServer.submit_intent(game_id, %{type: :end_turn, player_id: pid})
    end
  end

  defp do_accuse(game_id, snap, pid) do
    # Pick a wrong accusation deterministically: the first non-solution
    # character + weapon + room. With high probability this is wrong;
    # at minimum, it's deterministic.
    bad_char = first_non_solution(snap, "character")
    bad_weap = first_non_solution(snap, "weapon")
    bad_room = first_non_solution(snap, "room")

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

  defp cleanup(game_id) do
    Boltx.query!(
      MotifEngine.Bolt,
      """
      MATCH (g:Game {id: $id})
      OPTIONAL MATCH (n)-[:IN_GAME]->(g)
      DETACH DELETE g, n
      """,
      %{id: game_id}
    )
  end
end
