defmodule MotifEngine.SuggestionVisibilityTest do
  @moduledoc """
  ADR-0009 negative test for the suggestion history: the revealed card
  in a disproof is visible only to the suggester and the responder,
  never to other players, regardless of who's asking.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias MotifEngine.{GameServer, Snapshot}

  setup do
    game_id = "g-vis-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    players = [
      %{id: "#{game_id}/p1", name: "Alice"},
      %{id: "#{game_id}/p2", name: "Bob"},
      %{id: "#{game_id}/p3", name: "Carol"}
    ]

    {:ok, ^game_id} =
      Motif.start_game(MotifEngine.Rules.Clue, game_id: game_id, players: players, seed: 7)

    on_exit(fn -> cleanup(game_id) end)

    %{
      game_id: game_id,
      p1: "#{game_id}/p1",
      p2: "#{game_id}/p2",
      p3: "#{game_id}/p3"
    }
  end

  test "revealed_card is visible only to the suggester and disprover",
       %{game_id: gid, p1: p1, p2: p2, p3: p3} do
    # Deterministically pick a character + weapon p2 holds.
    {:ok, snap} = Snapshot.load(gid)
    p2_hand = Map.get(snap.players_hands, p2, [])
    p2_held = Enum.filter(snap.cards, &(&1.id in p2_hand))

    char =
      Enum.find(p2_held, &(&1.kind == "character")) ||
        Enum.find(snap.cards, &(&1.kind == "character"))

    weap =
      Enum.find(p2_held, &(&1.kind == "weapon")) ||
        Enum.find(snap.cards, &(&1.kind == "weapon"))

    :ok =
      GameServer.submit_intent(gid, %{
        type: :make_suggestion,
        player_id: p1,
        character_slug: char.slug,
        weapon_slug: weap.slug
      })

    # P2 should be able to disprove with the held card.
    reveal = Enum.find(p2_held, &(&1.kind in ["character", "weapon"]))

    :ok =
      GameServer.submit_intent(gid, %{
        type: :respond_to_suggestion,
        player_id: p2,
        card_slug: reveal.slug
      })

    reveal_slug = reveal.slug

    {:ok, view_p1} = MotifEngine.get_recent_suggestions(gid, p1)
    {:ok, view_p2} = MotifEngine.get_recent_suggestions(gid, p2)
    {:ok, view_p3} = MotifEngine.get_recent_suggestions(gid, p3)

    # Both p1 (suggester) and p2 (disprover) see the revealed card.
    assert [%{"revealed_card" => %{"slug" => ^reveal_slug}}] = view_p1
    assert [%{"revealed_card" => %{"slug" => ^reveal_slug}}] = view_p2

    # p3 sees the suggestion but NOT the revealed card.
    assert [entry] = view_p3
    assert entry["disprover_player_id"] == p2
    refute Map.has_key?(entry, "revealed_card")
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
