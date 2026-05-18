defmodule MotifWeb.TableLivePendingTest do
  @moduledoc """
  Regression test for the bug where a `[game]` PubSub event arriving
  while a turn was in flight got appended to `assigns.conversation` —
  only to be clobbered when the spawned turn process returned its
  (older) conversation in `{:turn_done, ...}`.

  Fix: messages that arrive while `loading?` is true are stashed in
  `:pending_messages` and flushed onto the end of the conversation when
  the turn returns. If any of those messages was a *nudge* (i.e. the
  player needs to act on it), a follow-up turn is kicked off
  automatically.

  We can't easily test the spawned-turn side-effect here without an LLM
  endpoint stub, but we can pin down the conversation-flushing
  invariant by exercising `handle_info/2` directly.
  """

  use ExUnit.Case, async: true

  alias MotifWeb.TableLive

  defp socket(extra) do
    assigns =
      Map.merge(
        %{
          player_id: "p-x",
          conversation: [],
          pending_messages: [],
          pending_nudge?: false,
          loading?: false,
          error: nil,
          system_prompt: "sys",
          tools: [],
          session_id: "ses-x",
          # LiveView's `assign/3` needs the change-tracking map; presence
          # of the key is enough for handle_info-level testing.
          __changed__: %{}
        },
        extra
      )

    %Phoenix.LiveView.Socket{assigns: assigns}
  end

  defp suggestion_made_payload(asking_player_id) do
    %{
      suggestion_id: "s-1",
      suggester_player_id: "other-player",
      asking_player_id: asking_player_id,
      cards: [
        %{kind: "character", name: "Miss Scarlet", slug: "scarlet"},
        %{kind: "weapon", name: "Rope", slug: "rope"},
        %{kind: "room", name: "Library", slug: "library"}
      ]
    }
  end

  describe "PubSub events while NOT loading" do
    test "appending a non-nudge note adds it directly to the conversation" do
      socket = socket(%{player_id: "p-spectator"})

      # spectator gets a :note (not their turn to disprove)
      {:noreply, new_socket} =
        TableLive.handle_info({:suggestion_made, suggestion_made_payload("p-asker")}, socket)

      assert length(new_socket.assigns.conversation) == 1
      assert [%{"role" => "user", "content" => "[game]" <> _}] = new_socket.assigns.conversation
      refute new_socket.assigns.loading?
      assert new_socket.assigns.pending_messages == []
    end
  end

  describe "PubSub events that arrive WHILE loading (the bug-B scenario)" do
    test "a note is stashed in :pending_messages, not appended to :conversation" do
      socket =
        socket(%{
          player_id: "p-spectator",
          loading?: true,
          conversation: [%{"role" => "user", "content" => "what's up?"}]
        })

      {:noreply, new_socket} =
        TableLive.handle_info({:suggestion_made, suggestion_made_payload("p-asker")}, socket)

      # Conversation is unchanged — the note is stashed, not appended.
      assert new_socket.assigns.conversation == socket.assigns.conversation
      assert length(new_socket.assigns.pending_messages) == 1
      refute new_socket.assigns.pending_nudge?
    end

    test "a NUDGE is stashed AND :pending_nudge? is set" do
      # The asking player gets a :nudge when a suggestion is made.
      socket =
        socket(%{
          player_id: "p-asker",
          loading?: true,
          conversation: [%{"role" => "user", "content" => "earlier message"}]
        })

      {:noreply, new_socket} =
        TableLive.handle_info({:suggestion_made, suggestion_made_payload("p-asker")}, socket)

      assert new_socket.assigns.conversation == socket.assigns.conversation
      assert length(new_socket.assigns.pending_messages) == 1
      assert new_socket.assigns.pending_nudge?
    end
  end

  describe "turn_done flushes pending messages" do
    test "pending notes get appended to the post-turn conversation" do
      socket =
        socket(%{
          loading?: true,
          conversation: [%{"role" => "user", "content" => "earlier"}],
          pending_messages: [
            %{"role" => "user", "content" => "[game] something happened"}
          ]
        })

      # The spawned turn returns its own (older-base + assistant block)
      # conversation. We use the same older base + one assistant entry
      # to simulate the spawn's result. Bug B was that this would
      # overwrite the pending message; the fix appends it back.
      returned =
        socket.assigns.conversation ++
          [%{"role" => "assistant", "content" => [%{"type" => "text", "text" => "ok"}]}]

      {:noreply, new_socket} = TableLive.handle_info({:turn_done, {:ok, returned}}, socket)

      assert List.last(new_socket.assigns.conversation)["content"] ==
               "[game] something happened"

      assert new_socket.assigns.pending_messages == []
      refute new_socket.assigns.loading?
    end

    test "if any pending message was a nudge, a follow-up turn is auto-triggered" do
      socket =
        socket(%{
          loading?: true,
          pending_nudge?: true,
          pending_messages: [
            %{"role" => "user", "content" => "[game] you're up to disprove"}
          ]
        })

      # We don't have a real LLM endpoint in this test, so we expect a
      # process to be spawned that will eventually crash (no endpoint).
      # The thing we're asserting is that :loading? stays true and
      # :pending_nudge? gets cleared, signalling "a follow-up turn was
      # kicked off."
      Process.flag(:trap_exit, true)
      {:noreply, new_socket} = TableLive.handle_info({:turn_done, {:ok, []}}, socket)

      assert new_socket.assigns.loading?
      refute new_socket.assigns.pending_nudge?
      assert new_socket.assigns.pending_messages == []
    end

    test "error result still flushes pending and clears nudge flag" do
      socket =
        socket(%{
          loading?: true,
          pending_nudge?: true,
          pending_messages: [%{"role" => "user", "content" => "[game] arrived during error"}],
          conversation: [%{"role" => "user", "content" => "earlier"}]
        })

      {:noreply, new_socket} = TableLive.handle_info({:turn_done, {:error, :boom}}, socket)

      assert List.last(new_socket.assigns.conversation)["content"] ==
               "[game] arrived during error"

      refute new_socket.assigns.pending_nudge?
      refute new_socket.assigns.loading?
      assert new_socket.assigns.pending_messages == []
      assert new_socket.assigns.error =~ "boom"
    end
  end
end
