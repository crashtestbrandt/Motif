defmodule MotifEngine.InvariantDeterminismTest do
  @moduledoc """
  ADR-0006 + plan verification section: "Capture a sequence of intents
  from a played game; replay against a fresh database; assert
  resulting graph is isomorphic to the original."

  We exercise this by:
    1. Creating game A with a fixed seed and player list.
    2. Running a canned intent sequence.
    3. Capturing the snapshot (normalized).
    4. Tearing the game down.
    5. Creating game B with **the same** game_id, seed, and players.
    6. Running the **same** intent sequence.
    7. Capturing the normalized snapshot.
    8. Asserting the two snapshots are equal.

  Normalization sorts list-valued fields so Neo4j return-order doesn't
  cause spurious failures.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias MotifEngine.{GameServer, Snapshot}

  @seed 4242

  @players [
    %{id: "g-det/p1", name: "Alice"},
    %{id: "g-det/p2", name: "Bob"},
    %{id: "g-det/p3", name: "Carol"}
  ]

  setup do
    on_exit(fn -> cleanup("g-det") end)
    :ok
  end

  test "same intent sequence → same graph state" do
    cleanup("g-det")

    snap_a = run_and_snapshot()
    cleanup("g-det")

    snap_b = run_and_snapshot()

    a = normalize(snap_a)
    b = normalize(snap_b)

    if a != b do
      diff =
        Enum.flat_map(Map.keys(a), fn k ->
          if a[k] != b[k], do: [{k, a[k], b[k]}], else: []
        end)

      flunk("""
      ADR-0006 violation: replay of identical intents produced different snapshots.
      Differing fields (first run vs second):
      #{Enum.map_join(diff, "\n\n", fn {k, av, bv} -> "  #{k}:\n    A: #{inspect(av)}\n    B: #{inspect(bv)}" end)}
      """)
    end
  end

  defp run_and_snapshot do
    {:ok, "g-det"} =
      Motif.start_game(MotifEngine.Rules.Clue,
        game_id: "g-det",
        players: @players,
        seed: @seed
      )

    p1 = "g-det/p1"
    p2 = "g-det/p2"

    # A fixed intent sequence covering move + suggestion + disprove +
    # end_turn flow.
    :ok = move(p1, "billiard")
    :ok = submit(%{type: :make_suggestion, player_id: p1, character_slug: "plum", weapon_slug: "knife"})

    # Whichever of p2 / p3 is being asked, have them respond with what
    # their hand allows. This is deterministic given the seed.
    handle_disprove_chain()

    :ok = submit(%{type: :end_turn, player_id: p1})

    :ok = move(p2, room_neighbor_of(p2))
    :ok = submit(%{type: :end_turn, player_id: p2})

    {:ok, snap} = Snapshot.load("g-det")
    snap
  end

  defp handle_disprove_chain do
    {:ok, snap} = Snapshot.load("g-det")

    case snap.pending_suggestion do
      nil ->
        :ok

      %{asking_player_id: asker} = sugg ->
        held = Map.get(snap.players_hands, asker, [])
        matching = Enum.find(held, &(&1 in sugg.suggested_card_ids))

        card_slug =
          if matching do
            Enum.find(snap.cards, &(&1.id == matching)).slug
          else
            nil
          end

        :ok =
          submit(%{
            type: :respond_to_suggestion,
            player_id: asker,
            card_slug: card_slug
          })

        # If chain continues, recurse.
        handle_disprove_chain()
    end
  end

  defp submit(intent), do: GameServer.submit_intent("g-det", intent)

  defp move(pid, room_slug) do
    submit(%{type: :move_to_room, player_id: pid, to_room_slug: room_slug})
  end

  defp room_neighbor_of(pid) do
    {:ok, snap} = Snapshot.load("g-det")
    char = Enum.find(snap.characters, &(&1.player_id == pid))
    snap.rooms[char.room_slug].connects_to |> hd()
  end

  # Sort all list-valued fields so the comparison is stable across runs
  # regardless of Neo4j's return order.
  defp normalize(snap) do
    snap
    |> Map.update!(:players, &Enum.sort_by(&1, fn p -> p.id end))
    |> Map.update!(:characters, &Enum.sort_by(&1, fn c -> c.id end))
    |> Map.update!(:cards, &Enum.sort_by(&1, fn c -> c.id end))
    |> Map.update!(:solution, &Enum.sort/1)
    |> Map.update!(:lost_player_ids, &Enum.sort/1)
    |> Map.update!(:players_hands, fn hands ->
      Map.new(hands, fn {pid, cards} -> {pid, Enum.sort(cards)} end)
    end)
    |> Map.update!(:rooms, fn rooms ->
      Map.new(rooms, fn {slug, room} ->
        {slug,
         room
         |> Map.update!(:connects_to, &Enum.sort/1)
         |> Map.update!(:secret_passages_to, &Enum.sort/1)}
      end)
    end)
    |> normalize_pending_suggestion()
  end

  defp normalize_pending_suggestion(snap) do
    case snap.pending_suggestion do
      nil ->
        snap

      sugg ->
        normalized =
          sugg
          |> Map.update!(:suggested_card_ids, &Enum.sort/1)
          |> Map.update!(:cannot_disprove_player_ids, &Enum.sort/1)

        Map.put(snap, :pending_suggestion, normalized)
    end
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
