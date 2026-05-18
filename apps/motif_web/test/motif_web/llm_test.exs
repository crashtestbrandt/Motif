defmodule MotifWeb.LLMTest do
  use ExUnit.Case, async: true

  alias MotifWeb.LLM

  defmodule StubTransport do
    @moduledoc false
    @behaviour MotifWeb.LLM.Transport

    def post(url, body, headers) do
      send(self(), {:posted, url, body, headers})
      {:ok, Process.get(:next_response, default_response())}
    end

    defp default_response do
      %{
        status: 200,
        body: %{
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => "hi"},
              "finish_reason" => "stop"
            }
          ]
        }
      }
    end
  end

  setup do
    Application.put_env(:motif_web, :llm_base_url, "http://127.0.0.1:9999/v1")
    Application.put_env(:motif_web, :llm_model, "test-model")
    :ok
  end

  describe "call/2 — request translation" do
    test "prepends a system message in the conversation" do
      LLM.call([%{"role" => "user", "content" => "hello"}],
        system: "you are a Clue detective",
        tools: [tool_descriptor("get_my_hand")],
        transport: StubTransport
      )

      assert_receive {:posted, _url, body, _headers}
      assert [%{"role" => "system", "content" => "you are a Clue detective"} | _] = body["messages"]
    end

    test "translates the MCP tool catalog into OpenAI's `function` shape" do
      LLM.call([%{"role" => "user", "content" => "x"}],
        system: "x",
        tools: [tool_descriptor("get_my_hand"), tool_descriptor("end_turn")],
        transport: StubTransport
      )

      assert_receive {:posted, _url, body, _headers}

      assert [
               %{
                 "type" => "function",
                 "function" => %{"name" => "get_my_hand", "parameters" => %{"type" => "object"}}
               },
               %{
                 "type" => "function",
                 "function" => %{"name" => "end_turn"}
               }
             ] = body["tools"]
    end

    test "translates an assistant tool_use block into OpenAI's tool_calls field" do
      conversation = [
        %{"role" => "user", "content" => "what's in my hand?"},
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "checking..."},
            %{"type" => "tool_use", "id" => "call_1", "name" => "get_my_hand", "input" => %{}}
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "call_1",
              "content" => "{\"cards\":[]}"
            }
          ]
        }
      ]

      LLM.call(conversation,
        system: "x",
        tools: [tool_descriptor("get_my_hand")],
        transport: StubTransport
      )

      assert_receive {:posted, _url, body, _headers}

      assert [
               %{"role" => "system"},
               %{"role" => "user", "content" => "what's in my hand?"},
               %{
                 "role" => "assistant",
                 "content" => "checking...",
                 "tool_calls" => [
                   %{
                     "id" => "call_1",
                     "type" => "function",
                     "function" => %{"name" => "get_my_hand", "arguments" => "{}"}
                   }
                 ]
               },
               %{"role" => "tool", "tool_call_id" => "call_1", "content" => "{\"cards\":[]}"}
             ] = body["messages"]
    end
  end

  describe "call/2 — response translation" do
    test "plain text response normalizes to a single text block + end_turn" do
      assert {:ok, %{content: [%{"type" => "text", "text" => "hi"}], stop_reason: "end_turn"}} =
               LLM.call([%{"role" => "user", "content" => "hi"}],
                 system: "x",
                 tools: [],
                 transport: StubTransport
               )
    end

    test "tool_calls in response become tool_use blocks + stop_reason=tool_use" do
      Process.put(:next_response, %{
        status: 200,
        body: %{
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => "call_42",
                    "type" => "function",
                    "function" => %{
                      "name" => "move_to_room",
                      "arguments" => "{\"to_room_slug\":\"study\"}"
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        }
      })

      assert {:ok, %{content: blocks, stop_reason: "tool_use"}} =
               LLM.call([%{"role" => "user", "content" => "go to study"}],
                 system: "x",
                 tools: [tool_descriptor("move_to_room")],
                 transport: StubTransport
               )

      assert [
               %{
                 "type" => "tool_use",
                 "id" => "call_42",
                 "name" => "move_to_room",
                 "input" => %{"to_room_slug" => "study"}
               }
             ] = blocks
    end

    test "malformed tool-call JSON normalizes to an empty input map" do
      Process.put(:next_response, %{
        status: 200,
        body: %{
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => "call_bad",
                    "type" => "function",
                    "function" => %{"name" => "end_turn", "arguments" => "this is not json"}
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        }
      })

      assert {:ok, %{content: [%{"type" => "tool_use", "input" => %{}}]}} =
               LLM.call([%{"role" => "user", "content" => "go"}],
                 system: "x",
                 tools: [],
                 transport: StubTransport
               )
    end
  end

  describe "call/2 — auth + URL" do
    test "POSTs to <base_url>/chat/completions" do
      LLM.call([%{"role" => "user", "content" => "x"}],
        system: "x",
        tools: [],
        transport: StubTransport
      )

      assert_receive {:posted, "http://127.0.0.1:9999/v1/chat/completions", _, _}
    end

    test "omits Authorization header when no api key is configured" do
      Application.delete_env(:motif_web, :llm_api_key)

      LLM.call([%{"role" => "user", "content" => "x"}],
        system: "x",
        tools: [],
        transport: StubTransport
      )

      assert_receive {:posted, _url, _body, headers}
      refute Enum.any?(headers, fn {k, _} -> String.downcase(k) == "authorization" end)
    end

    test "sets Bearer Authorization header when api key is configured" do
      Application.put_env(:motif_web, :llm_api_key, "lm-studio-key")

      LLM.call([%{"role" => "user", "content" => "x"}],
        system: "x",
        tools: [],
        transport: StubTransport
      )

      assert_receive {:posted, _url, _body, headers}
      assert {"authorization", "Bearer lm-studio-key"} in headers

      Application.delete_env(:motif_web, :llm_api_key)
    end

    test "HTTP errors are surfaced as {:error, {:http, status, body}}" do
      Process.put(:next_response, %{status: 500, body: %{"error" => "boom"}})

      assert {:error, {:http, 500, %{"error" => "boom"}}} =
               LLM.call([%{"role" => "user", "content" => "x"}],
                 system: "x",
                 tools: [],
                 transport: StubTransport
               )
    end
  end

  defp tool_descriptor(name) do
    %{
      "name" => name,
      "description" => "tool #{name}",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  end
end
