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
  def legal_actions(snapshot, player_id) do
    cond do
      snapshot[:status] == "over" ->
        []

      asking_player = asking_player_id(snapshot) ->
        if asking_player == player_id do
          disprove_options(snapshot, player_id)
        else
          []
        end

      snapshot.current_turn_player_id == player_id and player_id not in lost_player_ids(snapshot) ->
        normal_turn_actions(snapshot, player_id)

      true ->
        []
    end
  end

  defp normal_turn_actions(snapshot, player_id) do
    moves =
      case character_for(snapshot, player_id) do
        nil -> []
        char -> move_intents_from(snapshot, player_id, char.room_slug)
      end

    suggest =
      if snapshot[:can_suggest] && character_for(snapshot, player_id) do
        char = character_for(snapshot, player_id)

        if char.room_slug do
          [
            %{
              type: :make_suggestion,
              player_id: player_id,
              room_slug: char.room_slug,
              available_character_slugs: list_slugs(snapshot, :character),
              available_weapon_slugs: list_slugs(snapshot, :weapon)
            }
          ]
        else
          []
        end
      else
        []
      end

    accuse = [
      %{
        type: :make_accusation,
        player_id: player_id,
        available_character_slugs: list_slugs(snapshot, :character),
        available_weapon_slugs: list_slugs(snapshot, :weapon),
        available_room_slugs: list_slugs(snapshot, :room)
      }
    ]

    moves ++ suggest ++ accuse ++ [%{type: :end_turn, player_id: player_id}]
  end

  defp disprove_options(snapshot, player_id) do
    suggestion = snapshot.pending_suggestion
    matching = matching_held_cards(snapshot, player_id, suggestion.suggested_card_ids)

    case matching do
      [] ->
        [%{type: :respond_to_suggestion, player_id: player_id, card_slug: nil}]

      cards ->
        Enum.map(cards, fn card ->
          %{type: :respond_to_suggestion, player_id: player_id, card_slug: card.slug}
        end)
    end
  end

  defp matching_held_cards(snapshot, player_id, suggested_ids) do
    held_ids = Map.get(snapshot.players_hands, player_id, [])
    matching_ids = Enum.filter(held_ids, &(&1 in suggested_ids))
    Enum.filter(snapshot.cards, &(&1.id in matching_ids))
  end

  defp list_slugs(snapshot, :character) do
    snapshot.characters
    |> Enum.map(& &1.slug)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp list_slugs(_snapshot, :weapon), do: Enum.map(@weapons, &elem(&1, 0)) |> Enum.sort()

  defp list_slugs(snapshot, :room), do: snapshot.rooms |> Map.keys() |> Enum.sort()

  defp asking_player_id(snapshot) do
    case snapshot[:pending_suggestion] do
      nil -> nil
      %{asking_player_id: pid} -> pid
    end
  end

  defp lost_player_ids(snapshot), do: snapshot[:lost_player_ids] || []

  @impl true
  def apply_intent(snapshot, %{type: :move_to_room, player_id: pid, to_room_slug: dest}) do
    with :ok <- check_turn(snapshot, pid),
         {:ok, character} <- fetch_character(snapshot, pid),
         {:ok, from_slug} <- fetch_current_room(character),
         :ok <- check_destination_exists(snapshot, dest),
         :ok <- check_reachable(snapshot, from_slug, dest) do
      {:ok, move_mutations(snapshot.game_id, character.id, dest)}
    end
  end

  def apply_intent(snapshot, %{type: :end_turn, player_id: pid}) do
    with :ok <- check_game_active(snapshot),
         :ok <- check_no_pending_suggestion(snapshot),
         :ok <- check_turn(snapshot, pid) do
      {:ok, [advance_turn_mutation(snapshot.game_id), reset_can_suggest_mutation(snapshot.game_id)]}
    end
  end

  def apply_intent(snapshot, %{
        type: :make_suggestion,
        player_id: pid,
        character_slug: char_slug,
        weapon_slug: weap_slug
      }) do
    with :ok <- check_game_active(snapshot),
         :ok <- check_no_pending_suggestion(snapshot),
         :ok <- check_turn(snapshot, pid),
         :ok <- check_not_lost(snapshot, pid),
         :ok <- check_can_suggest(snapshot),
         {:ok, character} <- fetch_character(snapshot, pid),
         {:ok, room_slug} <- fetch_current_room(character),
         :ok <- check_slug_exists(snapshot, :character, char_slug),
         :ok <- check_slug_exists(snapshot, :weapon, weap_slug) do
      {:ok,
       suggestion_mutations(
         snapshot,
         pid,
         char_slug,
         weap_slug,
         room_slug
       )}
    end
  end

  def apply_intent(snapshot, %{
        type: :respond_to_suggestion,
        player_id: pid,
        card_slug: card_slug
      }) do
    with {:ok, suggestion} <- fetch_pending_suggestion(snapshot),
         :ok <- check_asking(suggestion, pid),
         {:ok, mutations} <-
           build_response_mutations(snapshot, suggestion, pid, card_slug) do
      {:ok, mutations}
    end
  end

  def apply_intent(snapshot, %{
        type: :make_accusation,
        player_id: pid,
        character_slug: char_slug,
        weapon_slug: weap_slug,
        room_slug: room_slug
      }) do
    with :ok <- check_game_active(snapshot),
         :ok <- check_no_pending_suggestion(snapshot),
         :ok <- check_turn(snapshot, pid),
         :ok <- check_not_lost(snapshot, pid),
         :ok <- check_slug_exists(snapshot, :character, char_slug),
         :ok <- check_slug_exists(snapshot, :weapon, weap_slug),
         :ok <- check_slug_exists(snapshot, :room, room_slug) do
      {:ok, accusation_mutations(snapshot, pid, char_slug, weap_slug, room_slug)}
    end
  end

  def apply_intent(_snapshot, intent), do: {:error, {:unknown_intent, intent}}

  @impl true
  def view_for(_snapshot, _player_id), do: %{}

  # ---- move logic ---------------------------------------------------------

  defp character_for(snapshot, player_id) do
    Enum.find(snapshot.characters, &(&1.player_id == player_id))
  end

  defp move_intents_from(snapshot, player_id, room_slug) do
    case snapshot.rooms[room_slug] do
      nil ->
        []

      room ->
        (room.connects_to ++ room.secret_passages_to)
        |> Enum.uniq()
        |> Enum.map(&%{type: :move_to_room, player_id: player_id, to_room_slug: &1})
    end
  end

  defp check_turn(snapshot, pid) do
    if snapshot.current_turn_player_id == pid, do: :ok, else: {:error, :not_your_turn}
  end

  defp fetch_character(snapshot, pid) do
    case character_for(snapshot, pid) do
      nil -> {:error, :player_has_no_character}
      char -> {:ok, char}
    end
  end

  defp fetch_current_room(%{room_slug: nil}), do: {:error, :character_not_placed}
  defp fetch_current_room(%{room_slug: slug}), do: {:ok, slug}

  defp check_destination_exists(snapshot, slug) do
    if Map.has_key?(snapshot.rooms, slug), do: :ok, else: {:error, {:unknown_room, slug}}
  end

  defp check_reachable(snapshot, from_slug, to_slug) do
    room = snapshot.rooms[from_slug]
    options = room.connects_to ++ room.secret_passages_to

    if to_slug in options do
      :ok
    else
      {:error, {:unreachable_room, from: from_slug, to: to_slug}}
    end
  end

  defp check_game_active(snapshot) do
    if snapshot[:status] == "over", do: {:error, :game_over}, else: :ok
  end

  defp check_no_pending_suggestion(snapshot) do
    if snapshot[:pending_suggestion],
      do: {:error, :suggestion_in_progress},
      else: :ok
  end

  defp check_not_lost(snapshot, pid) do
    if pid in (snapshot[:lost_player_ids] || []),
      do: {:error, :player_eliminated},
      else: :ok
  end

  defp check_can_suggest(snapshot) do
    if snapshot[:can_suggest] == false,
      do: {:error, :already_suggested_this_turn},
      else: :ok
  end

  defp check_slug_exists(snapshot, :character, slug) do
    if Enum.any?(snapshot.characters, &(&1.slug == slug)),
      do: :ok,
      else: {:error, {:unknown_character, slug}}
  end

  defp check_slug_exists(_snapshot, :weapon, slug) do
    if Enum.any?(@weapons, &(elem(&1, 0) == slug)),
      do: :ok,
      else: {:error, {:unknown_weapon, slug}}
  end

  defp check_slug_exists(snapshot, :room, slug) do
    if Map.has_key?(snapshot.rooms, slug),
      do: :ok,
      else: {:error, {:unknown_room, slug}}
  end

  defp fetch_pending_suggestion(snapshot) do
    case snapshot[:pending_suggestion] do
      nil -> {:error, :no_pending_suggestion}
      s -> {:ok, s}
    end
  end

  defp check_asking(suggestion, pid) do
    if suggestion.asking_player_id == pid,
      do: :ok,
      else: {:error, :not_your_turn_to_disprove}
  end

  defp move_mutations(game_id, character_id, dest_slug) do
    [
      Mutation.new(
        """
        MATCH (c:Character {id: $char_id})-[r:LOCATED_IN]->(:Room)
        DELETE r
        """,
        %{char_id: character_id}
      ),
      Mutation.new(
        """
        MATCH (c:Character {id: $char_id})
        MATCH (room:Room {slug: $dest_slug})-[:IN_GAME]->(:Game {id: $game_id})
        CREATE (c)-[:LOCATED_IN]->(room)
        """,
        %{char_id: character_id, dest_slug: dest_slug, game_id: game_id}
      )
    ]
  end

  defp advance_turn_mutation(game_id) do
    # Skip players marked :LOST when advancing turn order. Lost players
    # remain in the :NEXT ring (they still disprove suggestions) but
    # can never have :CURRENT_TURN.
    Mutation.new(
      """
      MATCH (g:Game {id: $game_id})-[r:CURRENT_TURN]->(cur:Player)
      WITH g, r, cur
      MATCH path = (cur)-[:NEXT*1..6]->(next:Player)
      WHERE NOT (next)-[:LOST]->(g)
      WITH g, r, next, length(path) AS hop
      ORDER BY hop ASC
      LIMIT 1
      DELETE r
      CREATE (g)-[:CURRENT_TURN]->(next)
      """,
      %{game_id: game_id}
    )
  end

  defp reset_can_suggest_mutation(game_id) do
    Mutation.new(
      "MATCH (g:Game {id: $game_id}) SET g.can_suggest = true",
      %{game_id: game_id}
    )
  end

  # ---- suggestion mutations ----------------------------------------------

  defp suggestion_mutations(snapshot, suggester_id, char_slug, weap_slug, room_slug) do
    game_id = snapshot.game_id
    # Deterministic id: derived from how many suggestions already exist
    # in the snapshot. Two replays of the same intent sequence against
    # the same starting state produce identical ids (ADR-0006 purity).
    suggestion_id = "#{game_id}/suggestion/#{(snapshot[:suggestion_count] || 0) + 1}"

    suggested_card_ids = [
      "#{game_id}/card/character/#{char_slug}",
      "#{game_id}/card/weapon/#{weap_slug}",
      "#{game_id}/card/room/#{room_slug}"
    ]

    asking_player_id = snapshot.next_player[suggester_id]

    [
      Mutation.new(
        """
        MATCH (g:Game {id: $game_id})
        MATCH (suggester:Player {id: $suggester_id})
        CREATE (s:Suggestion {
                  id: $sid,
                  state: 'pending',
                  made_at: timestamp()
                })-[:IN_GAME]->(g)
        CREATE (s)-[:MADE_BY]->(suggester)
        """,
        %{game_id: game_id, suggester_id: suggester_id, sid: suggestion_id}
      ),
      Mutation.new(
        """
        MATCH (s:Suggestion {id: $sid})
        UNWIND $card_ids AS card_id
        MATCH (c:Card {id: card_id})
        CREATE (s)-[:SUGGESTED]->(c)
        """,
        %{sid: suggestion_id, card_ids: suggested_card_ids}
      ),
      Mutation.new(
        # Move the SUGGESTED character pawn to this room (classic Clue
        # rule: even if that pawn belongs to someone else, they get
        # dragged into the room).
        """
        MATCH (char:Character {slug: $char_slug})-[:IN_GAME]->(g:Game {id: $game_id})
        OPTIONAL MATCH (char)-[old:LOCATED_IN]->(:Room)
        DELETE old
        WITH char, g
        MATCH (room:Room {slug: $room_slug})-[:IN_GAME]->(g)
        CREATE (char)-[:LOCATED_IN]->(room)
        """,
        %{game_id: game_id, char_slug: char_slug, room_slug: room_slug}
      ),
      Mutation.new(
        """
        MATCH (s:Suggestion {id: $sid})
        MATCH (p:Player {id: $asking_id})
        CREATE (s)-[:ASKING]->(p)
        """,
        %{sid: suggestion_id, asking_id: asking_player_id}
      ),
      Mutation.new(
        "MATCH (g:Game {id: $game_id}) SET g.can_suggest = false",
        %{game_id: game_id}
      )
    ]
  end

  # ---- response mutations ------------------------------------------------

  # Player IS disproving (revealed a card).
  defp build_response_mutations(snapshot, suggestion, pid, card_slug) when is_binary(card_slug) do
    revealed_card_id = card_id_by_slug(snapshot, card_slug)
    held_ids = Map.get(snapshot.players_hands, pid, [])

    cond do
      revealed_card_id == nil ->
        {:error, {:unknown_card, card_slug}}

      revealed_card_id not in held_ids ->
        {:error, :card_not_in_hand}

      revealed_card_id not in suggestion.suggested_card_ids ->
        {:error, :card_does_not_match_suggestion}

      true ->
        {:ok,
         [
           Mutation.new(
             """
             MATCH (s:Suggestion {id: $sid})-[ask:ASKING]->(:Player)
             MATCH (p:Player {id: $pid})
             MATCH (c:Card {id: $card_id})
             DELETE ask
             CREATE (s)-[:DISPROVED_BY]->(p)
             CREATE (s)-[:REVEALED]->(c)
             SET s.state = 'disproven'
             """,
             %{sid: suggestion.id, pid: pid, card_id: revealed_card_id}
           )
         ]}
    end
  end

  # Player claims they CANNOT disprove.
  defp build_response_mutations(snapshot, suggestion, pid, nil) do
    held_ids = Map.get(snapshot.players_hands, pid, [])

    if Enum.any?(held_ids, &(&1 in suggestion.suggested_card_ids)) do
      {:error, :must_disprove_with_held_card}
    else
      next = snapshot.next_player[pid]
      suggester_id = suggestion.suggester_id

      record_cannot =
        Mutation.new(
          """
          MATCH (s:Suggestion {id: $sid})-[ask:ASKING]->(:Player)
          MATCH (p:Player {id: $pid})
          DELETE ask
          CREATE (s)-[:CANNOT_DISPROVE]->(p)
          """,
          %{sid: suggestion.id, pid: pid}
        )

      cond do
        next == suggester_id ->
          # We've cycled back to the suggester — no one could disprove.
          {:ok,
           [
             record_cannot,
             Mutation.new(
               "MATCH (s:Suggestion {id: $sid}) SET s.state = 'unrefuted'",
               %{sid: suggestion.id}
             )
           ]}

        true ->
          {:ok,
           [
             record_cannot,
             Mutation.new(
               """
               MATCH (s:Suggestion {id: $sid})
               MATCH (p:Player {id: $next_id})
               CREATE (s)-[:ASKING]->(p)
               """,
               %{sid: suggestion.id, next_id: next}
             )
           ]}
      end
    end
  end

  defp card_id_by_slug(snapshot, slug) do
    snapshot.cards
    |> Enum.find(&(&1.slug == slug))
    |> case do
      nil -> nil
      %{id: id} -> id
    end
  end

  # ---- accusation mutations ----------------------------------------------

  defp accusation_mutations(snapshot, pid, char_slug, weap_slug, room_slug) do
    game_id = snapshot.game_id
    # Deterministic, snapshot-derived (see suggestion_mutations).
    accusation_id = "#{game_id}/accusation/#{(snapshot[:accusation_count] || 0) + 1}"

    accused_card_ids = [
      "#{game_id}/card/character/#{char_slug}",
      "#{game_id}/card/weapon/#{weap_slug}",
      "#{game_id}/card/room/#{room_slug}"
    ]

    correct? = MapSet.new(accused_card_ids) == MapSet.new(snapshot.solution)

    base = [
      Mutation.new(
        """
        MATCH (g:Game {id: $game_id})
        MATCH (p:Player {id: $pid})
        CREATE (a:Accusation {
                  id: $aid,
                  correct: $correct,
                  made_at: timestamp()
                })-[:IN_GAME]->(g)
        CREATE (a)-[:MADE_BY]->(p)
        """,
        %{game_id: game_id, pid: pid, aid: accusation_id, correct: correct?}
      ),
      Mutation.new(
        """
        MATCH (a:Accusation {id: $aid})
        UNWIND $card_ids AS card_id
        MATCH (c:Card {id: card_id})
        CREATE (a)-[:ACCUSES_OF]->(c)
        """,
        %{aid: accusation_id, card_ids: accused_card_ids}
      )
    ]

    outcome =
      if correct? do
        [
          Mutation.new(
            """
            MATCH (g:Game {id: $game_id})
            MATCH (p:Player {id: $pid})
            CREATE (g)-[:WON]->(p)
            SET g.status = 'over'
            """,
            %{game_id: game_id, pid: pid}
          )
        ]
      else
        wrong_accusation_mutations(snapshot, pid)
      end

    base ++ outcome
  end

  defp wrong_accusation_mutations(snapshot, pid) do
    game_id = snapshot.game_id

    mark_lost =
      Mutation.new(
        """
        MATCH (g:Game {id: $game_id})
        MATCH (p:Player {id: $pid})
        CREATE (p)-[:LOST]->(g)
        """,
        %{game_id: game_id, pid: pid}
      )

    remaining_after =
      Enum.reject(snapshot.players, fn p -> p.id == pid or p.id in lost_player_ids(snapshot) end)

    case remaining_after do
      [last] ->
        # Win-by-elimination: only one undefeated player remains.
        [
          mark_lost,
          Mutation.new(
            """
            MATCH (g:Game {id: $game_id})
            MATCH (winner:Player {id: $winner_id})
            CREATE (g)-[:WON]->(winner)
            SET g.status = 'over'
            """,
            %{game_id: game_id, winner_id: last.id}
          )
        ]

      _ ->
        [mark_lost, advance_turn_mutation(game_id), reset_can_suggest_mutation(game_id)]
    end
  end

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
      """
      CREATE (:Game {id: $id, rules: $rules, created_at: timestamp(),
                     can_suggest: true, status: 'active'})
      """,
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
    rows =
      for {slug, name} <- @characters,
          do: %{id: "#{game_id}/character/#{slug}", slug: slug, name: name}

    Mutation.new(
      """
      MATCH (g:Game {id: $game_id})
      UNWIND $rows AS r
      CREATE (:Character {id: r.id, slug: r.slug, name: r.name})-[:IN_GAME]->(g)
      """,
      %{game_id: game_id, rows: rows}
    )
  end

  defp create_weapons(game_id) do
    rows =
      for {slug, name} <- @weapons,
          do: %{id: "#{game_id}/weapon/#{slug}", slug: slug, name: name}

    Mutation.new(
      """
      MATCH (g:Game {id: $game_id})
      UNWIND $rows AS r
      CREATE (:Weapon {id: r.id, slug: r.slug, name: r.name})-[:IN_GAME]->(g)
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
    rows = Enum.map(cards, fn c -> Map.put(c, :slug, slug_from_card_id(c.id)) end)

    Mutation.new(
      """
      MATCH (g:Game {id: $game_id})
      UNWIND $rows AS r
      CREATE (:Card {id: r.id, kind: r.kind, slug: r.slug, name: r.name})-[:IN_GAME]->(g)
      """,
      %{game_id: game_id, rows: rows}
    )
  end

  defp slug_from_card_id(id) do
    # id is "<game>/card/<kind>/<slug>"
    id |> String.split("/") |> List.last()
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
