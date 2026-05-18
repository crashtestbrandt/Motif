defmodule MotifMcp.JsonRpc do
  @moduledoc """
  Minimal JSON-RPC 2.0 dispatcher for the MCP wire format.

  We implement the two methods needed for milestone 4:

    * `tools/list` — return the catalog.
    * `tools/call` — invoke a tool with `arguments`.

  All requests are required to be valid JSON-RPC 2.0 (jsonrpc: "2.0",
  numeric/string `id`, `method` string). Notifications (no `id`) are
  not supported in milestone 4.
  """

  alias MotifMcp.Tools

  @typep tool_ctx :: %{player_id: String.t(), game_id: String.t()}

  # Standard JSON-RPC error codes.
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @application_error -32_000

  @doc """
  Process a parsed JSON-RPC request map and return the response map
  (also a plain map; the caller is responsible for JSON encoding).
  """
  @spec handle(tool_ctx(), map()) :: map()
  def handle(ctx, %{"jsonrpc" => "2.0", "method" => method} = req) do
    id = Map.get(req, "id")
    params = Map.get(req, "params", %{})

    result =
      case method do
        "tools/list" ->
          {:ok, %{"tools" => Tools.catalog()}}

        "tools/call" ->
          dispatch_call(ctx, params)

        _ ->
          {:rpc_error, @method_not_found, "method not found: #{method}"}
      end

    finish(id, result)
  end

  def handle(_ctx, _bad) do
    finish(nil, {:rpc_error, @invalid_request, "invalid JSON-RPC 2.0 request"})
  end

  # ---- internals ---------------------------------------------------------

  defp dispatch_call(ctx, %{"name" => name} = params) do
    args = Map.get(params, "arguments", %{})

    case Tools.call(ctx, name, args) do
      {:ok, value} -> {:ok, value}
      {:error, {:unknown_tool, n}} -> {:rpc_error, @invalid_params, "unknown tool: #{n}"}
      {:error, reason} -> {:rpc_error, @application_error, format_error(reason)}
    end
  end

  defp dispatch_call(_ctx, _),
    do: {:rpc_error, @invalid_params, "tools/call requires `name` parameter"}

  defp finish(id, {:ok, value}),
    do: %{"jsonrpc" => "2.0", "id" => id, "result" => value}

  defp finish(id, {:rpc_error, code, message}),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  @doc """
  Translate engine errors into plain-English strings the LLM can
  actually read. Engine errors arrive as atoms (`:not_your_turn`) or
  small tuples (`{:unreachable_room, from: ..., to: ...}`); the LLM
  tool_result content is just text, so `inspect/1`-style output is
  unhelpful — especially for smaller models.

  Public for testing; not part of the JSON-RPC public surface.
  """
  @spec format_error(term()) :: String.t()
  def format_error(reason) when is_atom(reason), do: humanize(Atom.to_string(reason))
  def format_error(reason) when is_binary(reason), do: humanize(reason)
  def format_error({:unreachable_room, from: from, to: to}),
    do: "You can't move from the #{room_name(from)} to the #{room_name(to)} — they aren't connected."

  def format_error({:unknown_room, slug}),
    do: "There is no room called '#{slug}'."

  def format_error({:unknown_character, slug}),
    do: "There is no character called '#{slug}'."

  def format_error({:unknown_weapon, slug}),
    do: "There is no weapon called '#{slug}'."

  def format_error({:unknown_card, slug}),
    do: "There is no card called '#{slug}'."

  def format_error({:missing_opt, key}),
    do: "Missing required option: #{key}."

  def format_error({:too_few_players, n}),
    do: "Need at least 2 players (got #{n})."

  def format_error({:too_many_players, n}),
    do: "At most 6 players supported (got #{n})."

  def format_error({:unknown_intent, _}),
    do: "Unknown intent type."

  def format_error(reason), do: inspect(reason)

  defp humanize("not_your_turn"), do: "It's not your turn right now."

  defp humanize("not_your_turn_to_disprove"),
    do: "You are not the player currently being asked to disprove."

  defp humanize("suggestion_in_progress"),
    do: "A suggestion is in progress — wait until it's resolved before doing anything else."

  defp humanize("no_pending_suggestion"),
    do: "There is no pending suggestion to respond to."

  defp humanize("must_disprove_with_held_card"),
    do:
      "You hold at least one of the three cards in the suggestion and must reveal one of them. " <>
        "Call respond_to_suggestion with the slug of a matching card you hold — don't pass."

  defp humanize("card_not_in_hand"),
    do: "You don't hold the card you tried to reveal."

  defp humanize("card_does_not_match_suggestion"),
    do: "That card isn't one of the three cards in the current suggestion."

  defp humanize("already_suggested_this_turn"),
    do: "You've already made a suggestion this turn — make an accusation or end your turn."

  defp humanize("game_over"), do: "The game is over."

  defp humanize("player_eliminated"),
    do: "You made a wrong accusation earlier and can no longer take actions on your turn."

  defp humanize("player_has_no_character"),
    do: "You haven't been assigned a character in this game."

  defp humanize("character_not_placed"),
    do: "Your character isn't placed in a room yet."

  defp humanize("missing_args"),
    do: "Required arguments are missing or malformed."

  defp humanize("missing_arg_to_room_slug"),
    do: "Required argument missing: to_room_slug."

  defp humanize("invalid_player_shape"),
    do: "Player data is malformed."

  defp humanize("duplicate_player_ids"),
    do: "Player ids must be unique."

  defp humanize("invalid_players"),
    do: "Player list is malformed."

  defp humanize("not_placed"),
    do: "Your character isn't currently in a room."

  defp humanize("game_not_running"),
    do: "The game server isn't running."

  # Unknown engine error: return the raw atom/snake_case as-is. This
  # surfaces the gap rather than hiding it; future cases can be added.
  defp humanize(other), do: other

  defp room_name(slug) do
    case slug do
      "study" -> "Study"
      "hall" -> "Hall"
      "lounge" -> "Lounge"
      "library" -> "Library"
      "billiard" -> "Billiard Room"
      "dining" -> "Dining Room"
      "conservatory" -> "Conservatory"
      "ballroom" -> "Ballroom"
      "kitchen" -> "Kitchen"
      _ -> slug
    end
  end

  @doc "Build a parse-error response (used when the request body is malformed JSON)."
  @spec parse_error_response() :: map()
  def parse_error_response,
    do: %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => @parse_error, "message" => "parse error"}}
end
