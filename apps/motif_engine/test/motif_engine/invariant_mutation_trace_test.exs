defmodule MotifEngine.InvariantMutationTraceTest do
  @moduledoc """
  ADR-0010 + ADR-0006: the rule engine is the only sanctioned writer
  to the knowledge graph. We verify this with telemetry — every
  `[:motif_engine, :repo, :transaction]` event recorded during a game
  session must be paired with a preceding
  `[:motif_engine, :rules, :apply_intent]` event.

  This is a runtime invariant. It catches:
    * A new code path that writes through `Repo.transaction/1` without
      going through `apply_intent/3`.
    * A rule that bypasses the GameServer and writes directly.

  Setup-time transactions (game creation, schema bootstrap) are
  excluded by attaching the telemetry handler *after* the game is
  already created.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias MotifEngine.{GameServer, Snapshot}

  setup do
    game_id = "g-trace-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    players = [
      %{id: "#{game_id}/p1", name: "Alice"},
      %{id: "#{game_id}/p2", name: "Bob"}
    ]

    {:ok, ^game_id} =
      Motif.start_game(MotifEngine.Rules.Clue, game_id: game_id, players: players, seed: 11)

    # Attach the recording handler *now* — anything before this point
    # (game setup transactions) is intentionally not measured.
    handler_id = "trace-#{System.unique_integer([:positive])}"
    pid = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:motif_engine, :rules, :apply_intent, :start],
        [:motif_engine, :rules, :apply_intent, :stop],
        [:motif_engine, :repo, :transaction, :start],
        [:motif_engine, :repo, :transaction, :stop]
      ],
      fn event, measurements, metadata, _ ->
        send(pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      cleanup(game_id)
    end)

    %{game_id: game_id, p1: "#{game_id}/p1", p2: "#{game_id}/p2"}
  end

  test "every transaction is preceded by a rule invocation",
       %{game_id: gid, p1: p1, p2: p2} do
    # Run a small mix of intents.
    {:ok, snap0} = Snapshot.load(gid)
    assert snap0.current_turn_player_id == p1

    # P1 moves, then ends turn.
    {:ok, [move | _]} =
      GameServer.legal_actions(gid, p1)
      |> case do
        {:ok, actions} -> {:ok, Enum.filter(actions, &(&1.type == :move_to_room))}
        other -> other
      end

    :ok = GameServer.submit_intent(gid, move)
    :ok = GameServer.submit_intent(gid, %{type: :end_turn, player_id: p1})

    # P2 moves, then ends turn.
    {:ok, p2_actions} = GameServer.legal_actions(gid, p2)
    p2_move = Enum.find(p2_actions, &(&1.type == :move_to_room))
    :ok = GameServer.submit_intent(gid, p2_move)
    :ok = GameServer.submit_intent(gid, %{type: :end_turn, player_id: p2})

    events = drain_telemetry()

    # Filter to the success "stop" events only (those represent
    # completed operations).
    sequence =
      events
      |> Enum.filter(fn
        {[_, _, _, :stop], _, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {[_, _, action, _], _measurements, _metadata} -> action end)

    # The invariant: between consecutive transaction events there is
    # always a preceding apply_intent event. Walk the sequence and
    # assert it never sees :transaction without a recent :apply_intent.
    assert obeys_invariant?(sequence),
           """
           ADR-0010 violation: a Repo.transaction event was recorded that
           was not preceded by a Rules.apply_intent event in the same
           run_intent flow.

           Telemetry sequence (oldest first): #{inspect(sequence)}

           Expected each `:transaction` to be immediately preceded by
           `:apply_intent`.
           """

    # And while we're here: there should be at least one of each pair
    # (we did issue intents).
    assert Enum.count(sequence, &(&1 == :apply_intent)) >= 4
    assert Enum.count(sequence, &(&1 == :transaction)) >= 4
  end

  defp obeys_invariant?(sequence) do
    {ok?, _} =
      Enum.reduce(sequence, {true, false}, fn
        :apply_intent, {ok?, _saw_rule?} -> {ok?, true}
        :transaction, {ok?, saw_rule?} -> {ok? and saw_rule?, false}
      end)

    ok?
  end

  defp drain_telemetry(acc \\ []) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        drain_telemetry([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
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
