defmodule MotifEngine.Rules.Clue do
  @moduledoc """
  Clue (Cluedo) rules pack — the first concrete implementation of
  `MotifEngine.Rules` (ADR-0007). Rooms-as-graph model: no dice, no grid;
  movement is a traversal of `:CONNECTS` and `:SECRET_PASSAGE` edges.

  Milestone-2 scope: `setup/1` only. The remaining callbacks are declared
  so the behaviour is satisfied but raise/`{:error, ...}` until later
  milestones fill them in.
  """

  @behaviour MotifEngine.Rules

  alias MotifEngine.Cypher.Mutation

  # Fixed Clue domain. Slug = stable identifier component; name = display text.

  @characters [
    {"scarlet", "Miss Scarlet"},
    {"mustard", "Colonel Mustard"},
    {"white", "Mrs. White"},
    {"green", "Reverend Green"},
    {"peacock", "Mrs. Peacock"},
    {"plum", "Professor Plum"}
  ]

  @weapons [
    {"rope", "Rope"},
    {"pipe", "Lead Pipe"},
    {"knife", "Knife"},
    {"wrench", "Wrench"},
    {"candlestick", "Candlestick"},
    {"revolver", "Revolver"}
  ]

  @rooms [
    {"study", "Study"},
    {"hall", "Hall"},
    {"lounge", "Lounge"},
    {"library", "Library"},
    {"billiard", "Billiard Room"},
    {"dining", "Dining Room"},
    {"conservatory", "Conservatory"},
    {"ballroom", "Ballroom"},
    {"kitchen", "Kitchen"}
  ]

  # Undirected: stored as one edge per pair; queries use `MATCH (a)-[:CONNECTS]-(b)`.
  @corridors [
    {"study", "hall"},
    {"hall", "lounge"},
    {"study", "library"},
    {"hall", "billiard"},
    {"lounge", "dining"},
    {"library", "billiard"},
    {"billiard", "dining"},
    {"library", "conservatory"},
    {"billiard", "ballroom"},
    {"dining", "kitchen"},
    {"conservatory", "ballroom"},
    {"ballroom", "kitchen"}
  ]

  @secret_passages [
    {"study", "kitchen"},
    {"lounge", "conservatory"}
  ]

  # Every character starts in the Hall in this prototype. Classic Clue starts
  # each pawn on a doorway; we lose nothing by collapsing to a single room.
  @starting_room "hall"

  @min_players 2
  @max_players 6

  # ---- behaviour callbacks ------------------------------------------------

  @impl true
  def setup(opts) do
    with {:ok, game_id} <- fetch(opts, :game_id),
         {:ok, players} <- fetch(opts, :players),
         {:ok, seed} <- fetch(opts, :seed),
         :ok <- validate_players(players) do
      {:ok, build_mutations(game_id, players, seed)}
    end
  end

  @impl true
  def legal_actions(_snapshot, _player_id), do: []

  @impl true
  def apply_intent(_snapshot, _intent), do: {:error, :not_yet_implemented}

  @impl true
  def view_for(_snapshot, _player_id), do: %{}

  # ---- opt parsing & validation -------------------------------------------

  defp fetch(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, {:missing_opt, key}}
    end
  end

  defp validate_players(players) when is_list(players) do
    cond do
      length(players) < @min_players -> {:error, {:too_few_players, length(players)}}
      length(players) > @max_players -> {:error, {:too_many_players, length(players)}}
      not Enum.all?(players, &valid_player?/1) -> {:error, :invalid_player_shape}
      not unique_ids?(players) -> {:error, :duplicate_player_ids}
      true -> :ok
    end
  end

  defp validate_players(_), do: {:error, :invalid_players}

  defp valid_player?(%{id: id, name: name}) when is_binary(id) and is_binary(name), do: true
  defp valid_player?(_), do: false

  defp unique_ids?(players) do
    ids = Enum.map(players, & &1.id)
    length(Enum.uniq(ids)) == length(ids)
  end

  # ---- mutation assembly --------------------------------------------------

  defp build_mutations(game_id, players, seed) do
    cards = build_cards(game_id)
    {solution_ids, deals} = pick_solution_and_deal(cards, players, seed)
    character_assignments = assign_characters(game_id, players)

    [
      create_game(game_id),
      create_players(game_id, players),
      create_next_ring(game_id, players),
      set_current_turn(game_id, hd(players)),
      create_characters(game_id),
      create_weapons(game_id),
      create_rooms(game_id),
      create_corridors(game_id),
      create_secret_passages(game_id),
      create_cards(game_id, cards),
      create_solution(game_id, solution_ids),
      create_holds(deals),
      create_plays_as(character_assignments),
      place_characters_in_starting_room(game_id)
    ]
  end

  defp build_cards(game_id) do
    chars = for {slug, name} <- @characters, do: card(game_id, "character", slug, name)
    weaps = for {slug, name} <- @weapons, do: card(game_id, "weapon", slug, name)
    rooms = for {slug, name} <- @rooms, do: card(game_id, "room", slug, name)
    chars ++ weaps ++ rooms
  end

  defp card(game_id, kind, slug, name) do
    %{id: "#{game_id}/card/#{kind}/#{slug}", kind: kind, name: name}
  end

  defp pick_solution_and_deal(cards, players, seed) do
    rng = :rand.seed_s(:exsplus, {seed, seed, seed})
    by_kind = Enum.group_by(cards, & &1.kind)

    {solution_char, rng} = pick_one(by_kind["character"], rng)
    {solution_weapon, rng} = pick_one(by_kind["weapon"], rng)
    {solution_room, rng} = pick_one(by_kind["room"], rng)

    solution_ids = [solution_char.id, solution_weapon.id, solution_room.id]

    remaining =
      Enum.reject(cards, fn c -> c.id in solution_ids end)

    {shuffled, _rng} = shuffle(remaining, rng)

    deals =
      shuffled
      |> Enum.with_index()
      |> Enum.map(fn {c, idx} ->
        %{player_id: Enum.at(players, rem(idx, length(players))).id, card_id: c.id}
      end)

    {solution_ids, deals}
  end

  defp pick_one(list, rng) do
    {n, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, n - 1), rng}
  end

  defp shuffle(list, rng) do
    {tagged, rng} =
      Enum.map_reduce(list, rng, fn item, rng ->
        {x, rng} = :rand.uniform_s(rng)
        {{x, item}, rng}
      end)

    sorted = tagged |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    {sorted, rng}
  end

  defp assign_characters(game_id, players) do
    players
    |> Enum.zip(@characters)
    |> Enum.map(fn {player, {char_slug, _name}} ->
      %{player_id: player.id, character_id: "#{game_id}/character/#{char_slug}"}
    end)
  end

  # ---- individual mutations -----------------------------------------------

  defp create_game(game_id) do
    Mutation.new(
      "CREATE (:Game {id: $id, rules: $rules, created_at: timestamp()})",
      %{id: game_id, rules: Atom.to_string(__MODULE__)}
    )
  end

  defp create_players(game_id, players) do
    Mutation.new(
      """
      MATCH (g:Game {id: $game_id})
      UNWIND $players AS p
      CREATE (player:Player {id: p.id, name: p.name})-[:IN_GAME]->(g)
      """,
      %{game_id: game_id, players: players}
    )
  end

  defp create_next_ring(game_id, players) do
    ids = Enum.map(players, & &1.id)
    pairs = Enum.zip(ids, tl(ids) ++ [hd(ids)]) |> Enum.map(fn {f, t} -> %{from: f, to: t} end)

    Mutation.new(
      """
      MATCH (g:Game {id: $game_id})
      UNWIND $pairs AS pair
      MATCH (a:Player {id: pair.from})-[:IN_GAME]->(g)
      MATCH (b:Player {id: pair.to})-[:IN_GAME]->(g)
      CREATE (a)-[:NEXT]->(b)
      """,
      %{game_id: game_id, pairs: pairs}
    )
  end

  defp set_current_turn(game_id, first_player) do
    Mutation.new(
      """
      MATCH (g:Game {id: $game_id})
      MATCH (p:Player {id: $player_id})-[:IN_GAME]->(g)
      CREATE (g)-[:CURRENT_TURN]->(p)
      """,
      %{game_id: game_id, player_id: first_player.id}
    )
  end

  defp create_characters(game_id) do
    rows = for {slug, name} <- @characters, do: %{id: "#{game_id}/character/#{slug}", name: name}

    Mutation.new(
      """
      MATCH (g:Game {id: $game_id})
      UNWIND $rows AS r
      CREATE (:Character {id: r.id, name: r.name})-[:IN_GAME]->(g)
      """,
      %{game_id: game_id, rows: rows}
    )
  end

  defp create_weapons(game_id) do
    rows = for {slug, name} <- @weapons, do: %{id: "#{game_id}/weapon/#{slug}", name: name}

    Mutation.new(
      """
      MATCH (g:Game {id: $game_id})
      UNWIND $rows AS r
      CREATE (:Weapon {id: r.id, name: r.name})-[:IN_GAME]->(g)
      """,
      %{game_id: game_id, rows: rows}
    )
  end

  defp create_rooms(game_id) do
    rows = for {slug, name} <- @rooms, do: %{id: "#{game_id}/room/#{slug}", slug: slug, name: name}

    Mutation.new(
      """
      MATCH (g:Game {id: $game_id})
      UNWIND $rows AS r
      CREATE (:Room {id: r.id, slug: r.slug, name: r.name})-[:IN_GAME]->(g)
      """,
      %{game_id: game_id, rows: rows}
    )
  end

  defp create_corridors(game_id) do
    rows =
      for {from, to} <- @corridors,
          do: %{from: "#{game_id}/room/#{from}", to: "#{game_id}/room/#{to}"}

    Mutation.new(
      """
      UNWIND $rows AS r
      MATCH (a:Room {id: r.from})
      MATCH (b:Room {id: r.to})
      CREATE (a)-[:CONNECTS]->(b)
      """,
      %{rows: rows}
    )
  end

  defp create_secret_passages(game_id) do
    rows =
      for {from, to} <- @secret_passages,
          do: %{from: "#{game_id}/room/#{from}", to: "#{game_id}/room/#{to}"}

    Mutation.new(
      """
      UNWIND $rows AS r
      MATCH (a:Room {id: r.from})
      MATCH (b:Room {id: r.to})
      CREATE (a)-[:SECRET_PASSAGE]->(b)
      """,
      %{rows: rows}
    )
  end

  defp create_cards(game_id, cards) do
    Mutation.new(
      """
      MATCH (g:Game {id: $game_id})
      UNWIND $rows AS r
      CREATE (:Card {id: r.id, kind: r.kind, name: r.name})-[:IN_GAME]->(g)
      """,
      %{game_id: game_id, rows: cards}
    )
  end

  defp create_solution(game_id, solution_ids) do
    Mutation.new(
      """
      MATCH (g:Game {id: $game_id})
      UNWIND $ids AS card_id
      MATCH (c:Card {id: card_id})-[:IN_GAME]->(g)
      CREATE (g)-[:SOLUTION]->(c)
      """,
      %{game_id: game_id, ids: solution_ids}
    )
  end

  defp create_holds(deals) do
    Mutation.new(
      """
      UNWIND $rows AS r
      MATCH (p:Player {id: r.player_id})
      MATCH (c:Card {id: r.card_id})
      CREATE (p)-[:HOLDS]->(c)
      """,
      %{rows: deals}
    )
  end

  defp create_plays_as(assignments) do
    Mutation.new(
      """
      UNWIND $rows AS r
      MATCH (p:Player {id: r.player_id})
      MATCH (c:Character {id: r.character_id})
      CREATE (p)-[:PLAYS_AS]->(c)
      """,
      %{rows: assignments}
    )
  end

  defp place_characters_in_starting_room(game_id) do
    Mutation.new(
      """
      MATCH (g:Game {id: $game_id})
      MATCH (room:Room {slug: $starting_room})-[:IN_GAME]->(g)
      MATCH (char:Character)-[:IN_GAME]->(g)
      CREATE (char)-[:LOCATED_IN]->(room)
      """,
      %{game_id: game_id, starting_room: @starting_room}
    )
  end
end
