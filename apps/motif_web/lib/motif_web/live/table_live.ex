defmodule MotifWeb.TableLive do
  @moduledoc """
  One LiveView process per player session (ADR-0012). Holds the
  conversation, the MCP session id, and the tool-use loop that bridges
  the two.
  """

  use MotifWeb, :live_view

  alias MotifMcp.Auth
  alias MotifEngine.Events
  alias MotifWeb.{LLM, McpClient}

  @impl true
  def mount(%{"game_id" => game_id, "player_id" => player_id}, _session, socket) do
    socket =
      socket
      |> assign(:game_id, game_id)
      |> assign(:player_id, player_id)
      |> assign(:player_name, derive_player_name(player_id))
      |> assign(:conversation, [])
      |> assign(:pending_messages, [])
      |> assign(:pending_nudge?, false)
      |> assign(:loading?, false)
      |> assign(:error, nil)
      |> assign(:input, "")
      |> assign(:session_id, nil)
      |> assign(:tools, [])
      |> assign(:system_prompt, "")
      |> assign(:page_title, "motif")

    if connected?(socket) do
      :ok = Events.subscribe(game_id)

      with {:ok, token} <- Auth.issue_token(game_id, player_id),
           {:ok, session_id} <- McpClient.open_session(token),
           {:ok, tools} <- McpClient.list_tools(session_id) do
        {:ok,
         socket
         |> assign(:session_id, session_id)
         |> assign(:tools, tools)
         |> assign(:system_prompt, system_prompt(player_id))
         |> assign(:page_title, "motif · #{derive_player_name(player_id)}")}
      else
        {:error, reason} ->
          {:ok, assign(socket, :error, "could not start session: #{inspect(reason)}")}
      end
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("send", %{"input" => text}, socket) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:noreply, socket}

      socket.assigns.loading? ->
        {:noreply, socket}

      socket.assigns.session_id == nil ->
        {:noreply, assign(socket, error: "session is not connected")}

      true ->
        user_msg = %{"role" => "user", "content" => text}
        new_conv = socket.assigns.conversation ++ [user_msg]
        start_turn(self(), new_conv, socket.assigns)

        {:noreply,
         socket
         |> assign(:conversation, new_conv)
         |> assign(:loading?, true)
         |> assign(:input, "")}
    end
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:turn_done, {:ok, conversation}}, socket) do
    # The turn we spawned has finished. Apply any [game] notes that
    # arrived from PubSub *during* the turn — those were stashed in
    # :pending_messages so they wouldn't be clobbered when the turn's
    # result conversation came back. If any of those pending messages
    # was a "nudge" (an event the LLM should act on), kick off a new
    # turn now to process them.
    {conversation, socket} = flush_pending(conversation, socket)

    if socket.assigns.pending_nudge? do
      start_turn(self(), conversation, socket.assigns)

      {:noreply,
       socket
       |> assign(:conversation, conversation)
       |> assign(:pending_nudge?, false)
       |> assign(:loading?, true)}
    else
      {:noreply,
       socket
       |> assign(:conversation, conversation)
       |> assign(:loading?, false)}
    end
  end

  def handle_info({:turn_done, {:error, reason}}, socket) do
    {conversation, socket} = flush_pending(socket.assigns.conversation, socket)

    {:noreply,
     socket
     |> assign(:conversation, conversation)
     |> assign(:pending_nudge?, false)
     |> assign(:error, format_error(reason))
     |> assign(:loading?, false)}
  end

  # ---- cross-player events ------------------------------------------------

  def handle_info({:suggestion_made, payload}, socket) do
    handle_game_event(socket, suggestion_made_message(payload, socket.assigns.player_id))
  end

  def handle_info({:suggestion_response, payload}, socket) do
    handle_game_event(socket, suggestion_response_message(payload, socket.assigns.player_id))
  end

  def handle_info({:accusation_resolved, payload}, socket) do
    handle_game_event(socket, accusation_message(payload, socket.assigns.player_id))
  end

  defp handle_game_event(socket, :ignore), do: {:noreply, socket}

  defp handle_game_event(socket, {:note, text}) do
    if socket.assigns.loading? do
      # A turn is running; stash so the spawned process's returned
      # conversation doesn't overwrite the note when it lands.
      {:noreply, stash_message(socket, note_msg(text))}
    else
      {:noreply, append_note(socket, text)}
    end
  end

  defp handle_game_event(socket, {:nudge, text}) do
    if socket.assigns.loading? do
      # Stash AND remember to re-trigger when the current turn finishes.
      {:noreply,
       socket
       |> stash_message(note_msg(text))
       |> assign(:pending_nudge?, true)}
    else
      socket = append_note(socket, text)
      start_turn(self(), socket.assigns.conversation, socket.assigns)
      {:noreply, assign(socket, loading?: true)}
    end
  end

  defp note_msg(text), do: %{"role" => "user", "content" => "[game] " <> text}

  defp append_note(socket, text) do
    assign(socket, :conversation, socket.assigns.conversation ++ [note_msg(text)])
  end

  defp stash_message(socket, msg) do
    update(socket, :pending_messages, fn pending -> pending ++ [msg] end)
  end

  defp flush_pending(conversation, socket) do
    pending = socket.assigns.pending_messages
    {conversation ++ pending, assign(socket, :pending_messages, [])}
  end

  # A suggestion just landed. Three audiences:
  #   * the asking player → must respond → :nudge
  #   * the suggester → informational only
  #   * other players → informational only
  defp suggestion_made_message(payload, viewer_id) do
    %{
      suggester_player_id: suggester,
      asking_player_id: asking,
      cards: cards
    } = payload

    card_phrase = cards |> Enum.map_join(", ", & &1.name)

    cond do
      asking == viewer_id ->
        {:nudge,
         "You are being asked to disprove the suggestion: #{card_phrase}. " <>
           "If you hold any of those cards, reveal one with respond_to_suggestion. " <>
           "If you hold none, pass with card_slug: null."}

      suggester == viewer_id ->
        {:note, "Your suggestion is out (#{card_phrase}). Waiting on the next player to respond."}

      true ->
        {:note, "A suggestion was made: #{card_phrase}. " <>
                "The next player is being asked to disprove."}
    end
  end

  # A response landed. Possible audiences for an event with these fields:
  defp suggestion_response_message(payload, viewer_id) do
    %{
      responder_player_id: responder,
      disproved?: disproved?,
      asking_player_id: next_asking,
      revealed_card: revealed,
      revealed_to_player_id: revealed_to
    } = payload

    cond do
      # Card was revealed and I'm the one allowed to see it.
      disproved? and revealed_to == viewer_id and revealed != nil ->
        {:nudge,
         "Disproved: a player showed you the #{revealed.name}. " <>
           "Decide whether to accuse, move, or end turn."}

      # I responded (whether disproved or not).
      responder == viewer_id ->
        if disproved? do
          {:note, "You disproved the suggestion."}
        else
          {:note, "You said you couldn't disprove."}
        end

      # I'm next to disprove.
      next_asking == viewer_id ->
        {:nudge,
         "The previous player couldn't disprove. " <>
           "Now you are being asked. Use respond_to_suggestion."}

      # Public resolution.
      disproved? ->
        {:note, "The suggestion was disproved by someone (card hidden)."}

      next_asking == nil ->
        {:note, "No one could disprove the suggestion."}

      true ->
        :ignore
    end
  end

  defp accusation_message(payload, viewer_id) do
    %{
      accuser_player_id: accuser,
      correct?: correct?,
      game_over?: game_over?,
      winner_player_id: winner
    } = payload

    cond do
      correct? and winner == viewer_id ->
        {:note, "You accused correctly. You win!"}

      correct? ->
        {:note, "The game is over: another player accused correctly and won."}

      accuser == viewer_id ->
        {:note, "Your accusation was wrong. You're eliminated from acting but " <>
                "your hand will still disprove future suggestions."}

      game_over? and winner == viewer_id ->
        {:note,
         "Everyone else has been eliminated. You win by elimination!"}

      game_over? ->
        {:note, "The game ended: only one player remained after a wrong accusation."}

      true ->
        {:note, "A wrong accusation was made; that player is eliminated from acting."}
    end
  end

  # ---- the tool-use loop -------------------------------------------------

  defp start_turn(parent_pid, conversation, assigns) do
    system = assigns.system_prompt
    tools = assigns.tools
    session_id = assigns.session_id

    spawn_link(fn ->
      result = run_turn(conversation, system, tools, session_id)
      send(parent_pid, {:turn_done, result})
    end)
  end

  defp run_turn(conversation, system, tools, session_id, depth \\ 0)

  defp run_turn(conversation, system, tools, session_id, depth) when depth < 8 do
    case LLM.call(conversation, system: system, tools: tools) do
      {:ok, %{content: blocks, stop_reason: stop_reason}} ->
        assistant_msg = %{"role" => "assistant", "content" => blocks}
        conversation = conversation ++ [assistant_msg]

        tool_uses = for %{"type" => "tool_use"} = b <- blocks, do: b

        cond do
          tool_uses == [] ->
            {:ok, conversation}

          stop_reason == "tool_use" or tool_uses != [] ->
            results = Enum.map(tool_uses, &execute_tool(&1, session_id))
            conversation = conversation ++ [%{"role" => "user", "content" => results}]
            run_turn(conversation, system, tools, session_id, depth + 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_turn(_conversation, _system, _tools, _session_id, _depth),
    do: {:error, :tool_use_depth_exceeded}

  defp execute_tool(%{"id" => id, "name" => name, "input" => input}, session_id) do
    case McpClient.call_tool(session_id, name, input || %{}) do
      {:ok, result} ->
        %{
          "type" => "tool_result",
          "tool_use_id" => id,
          "content" => [%{"type" => "text", "text" => Jason.encode!(result)}]
        }

      {:error, reason} ->
        %{
          "type" => "tool_result",
          "tool_use_id" => id,
          "is_error" => true,
          "content" => [%{"type" => "text", "text" => format_error(reason)}]
        }
    end
  end

  # ---- system prompt -----------------------------------------------------

  defp system_prompt(player_id) do
    name = derive_player_name(player_id)

    """
    You are #{name}, a detective in a game of Clue (Cluedo). You are
    trying to deduce who committed the murder, with what weapon, and in
    which room — the three cards held in the hidden solution envelope.

    The game state lives in a knowledge graph you can only read through
    the MCP tools below. Always call the appropriate tool rather than
    guessing. Never claim to know another player's hand — you cannot
    see it; the engine enforces this.

    Tools available:
      - get_my_hand: your private hand of cards.
      - get_my_location: the room your character is in.
      - list_legal_actions: what you can do right now. Read this often;
        it is the source of truth for what's possible.
      - list_recent_suggestions: the suggestion history so far. The
        specific card revealed in a disproof is visible only on
        suggestions you made or disproved.
      - move_to_room: move your character to an adjacent room.
      - make_suggestion: propose <character> in your current room with
        <weapon>. Other players are then asked to disprove.
      - respond_to_suggestion: only callable when you are being asked.
        Reveal one of your cards that matches the suggestion, or pass
        with card_slug: null if you hold none of the three.
      - make_accusation: final guess. Correct = win, wrong = you're
        eliminated from acting.
      - end_turn: yield to the next player.

    [game]-prefixed messages in this conversation are system notes from
    the engine (e.g. "you're being asked to disprove..."). Treat them
    as authoritative and act on them — typically by calling
    list_legal_actions to see your options, then the appropriate tool.

    Style:
      - Be concise. One short paragraph per response.
      - When the user gives a directive, call the matching tool and
        report what happened. If illegal, explain why and offer the
        closest legal option.
      - When the user asks an open question, feel free to reason a bit,
        but use tools to ground anything factual.
      - If a tool returns an error, explain it in plain language.
    """
  end

  defp derive_player_name(player_id) do
    case String.split(player_id, "/") do
      [_game, "player", n] when is_binary(n) -> "Player " <> n
      _ -> player_id
    end
  end

  defp format_error({:rpc, _code, message}) when is_binary(message), do: message
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)

  # ---- render ------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container">
      <p class="mono" style="color: var(--muted); font-size: 0.8rem;">
        game <code>{@game_id}</code> · you are <strong>{@player_name}</strong>
      </p>

      <%= if @error do %>
        <div style="background: #fdd; color: #800; padding: 0.5rem 0.75rem; border-radius: 4px; margin: 0.5rem 0;">
          {@error}
        </div>
      <% end %>

      <div id="messages" style="margin: 1rem 0; min-height: 50vh;">
        <%= for {role, blocks, idx} <- render_messages(@conversation) do %>
          <.message_bubble role={role} blocks={blocks} idx={idx} />
        <% end %>

        <%= if @loading? do %>
          <div style="color: var(--muted); font-style: italic;">…thinking</div>
        <% end %>
      </div>

      <form phx-submit="send" style="display: flex; gap: 0.5rem; border-top: 1px solid var(--border); padding-top: 0.75rem;">
        <input
          type="text"
          name="input"
          value={@input}
          placeholder="ask Motif — try: 'what's my hand?' or 'move to the study'"
          autocomplete="off"
          autofocus
          disabled={@loading? || is_nil(@session_id)}
          style="flex: 1; padding: 0.5rem 0.75rem; font: inherit; background: var(--bg); color: var(--fg); border: 1px solid var(--border); border-radius: 4px;"
        />
        <button
          type="submit"
          disabled={@loading? || is_nil(@session_id)}
          style="padding: 0.5rem 1rem; background: var(--accent); color: var(--bg); border: 0; border-radius: 4px; cursor: pointer; font: inherit;"
        >
          Send
        </button>
      </form>
    </div>
    """
  end

  attr :role, :atom, required: true
  attr :blocks, :any, required: true
  attr :idx, :integer, required: true

  defp message_bubble(%{role: :user} = assigns) do
    ~H"""
    <div style="margin: 0.5rem 0; padding: 0.5rem 0.75rem; background: var(--user-bubble); border-radius: 6px;">
      <div style="font-size: 0.7rem; color: var(--muted); margin-bottom: 0.25rem;">you</div>
      <div style="white-space: pre-wrap;">{@blocks}</div>
    </div>
    """
  end

  defp message_bubble(%{role: :assistant} = assigns) do
    ~H"""
    <div style="margin: 0.5rem 0; padding: 0.5rem 0.75rem; background: var(--asst-bubble); border-radius: 6px;">
      <div style="font-size: 0.7rem; color: var(--muted); margin-bottom: 0.25rem;">Motif</div>
      <%= for block <- @blocks do %>
        <.assistant_block block={block} />
      <% end %>
    </div>
    """
  end

  defp message_bubble(%{role: :tool_results} = assigns) do
    ~H"""
    <div style="margin: 0.25rem 0;">
      <%= for block <- @blocks do %>
        <.tool_result_block block={block} />
      <% end %>
    </div>
    """
  end

  attr :block, :map, required: true

  defp assistant_block(%{block: %{"type" => "text", "text" => _}} = assigns) do
    ~H"""
    <div style="white-space: pre-wrap;">{@block["text"]}</div>
    """
  end

  defp assistant_block(%{block: %{"type" => "tool_use"}} = assigns) do
    ~H"""
    <div class="mono" style="margin: 0.4rem 0; padding: 0.35rem 0.6rem; background: var(--tool-bubble); border-radius: 4px; font-size: 0.8rem;">
      → {@block["name"]}({Jason.encode!(@block["input"])})
    </div>
    """
  end

  defp assistant_block(assigns) do
    ~H"""
    <div class="mono" style="color: var(--muted); font-size: 0.75rem;">[{@block["type"]}]</div>
    """
  end

  defp tool_result_block(%{block: %{"type" => "tool_result"}} = assigns) do
    text =
      case assigns.block["content"] do
        [%{"type" => "text", "text" => t} | _] -> t
        other -> inspect(other)
      end

    assigns = assign(assigns, :text, text)
    is_err = Map.get(assigns.block, "is_error", false)
    assigns = assign(assigns, :is_err, is_err)

    ~H"""
    <div class="mono" style={"margin: 0.25rem 0; padding: 0.35rem 0.6rem; background: var(--tool-bubble); border-radius: 4px; font-size: 0.78rem; color: " <> if(@is_err, do: "#a00", else: "var(--fg)") <> ";"}>
      ← {@text}
    </div>
    """
  end

  defp tool_result_block(assigns), do: ~H""

  # Flatten the conversation into UI items: user text, assistant blocks,
  # tool_result blocks.
  defp render_messages(conversation) do
    conversation
    |> Enum.with_index()
    |> Enum.flat_map(fn {msg, idx} -> message_to_ui(msg, idx) end)
  end

  defp message_to_ui(%{"role" => "user", "content" => content}, idx) when is_binary(content),
    do: [{:user, content, idx}]

  defp message_to_ui(%{"role" => "user", "content" => blocks}, idx) when is_list(blocks) do
    # User-role messages with block content are tool_result blocks (from us).
    [{:tool_results, blocks, idx}]
  end

  defp message_to_ui(%{"role" => "assistant", "content" => blocks}, idx) when is_list(blocks),
    do: [{:assistant, blocks, idx}]

  defp message_to_ui(_, _), do: []
end
