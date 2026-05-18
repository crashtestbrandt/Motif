defmodule MotifWeb.LLM do
  @moduledoc """
  Client for a self-hosted, OpenAI-compatible LLM endpoint (ADR-0014).

  Speaks `POST /v1/chat/completions`. Works against LM Studio, vLLM,
  llama.cpp's server, Ollama (with `/v1` prefix), TGI, and any other
  server that implements the OpenAI Chat Completions spec.

  The HTTP transport is pluggable via the `:transport` option so tests
  can stub responses without touching the network. The default
  transport (`MotifWeb.LLM.HttpTransport`) uses `Req`.

  This module is the only place that knows the OpenAI wire shape. Its
  callers (`MotifWeb.TableLive` and tests) work with a normalized
  content-block representation:

      %{content: [
          %{"type" => "text", "text" => "..."},
          %{"type" => "tool_use", "id" => "...", "name" => "...", "input" => %{}}
        ],
        stop_reason: "end_turn" | "tool_use" | ...,
        raw: <original response map>}

  Tool results that the caller sends back are also in content-block
  form (`%{"type" => "tool_result", "tool_use_id" => ..., "content" => ...}`);
  this module translates them to OpenAI's `role: "tool"` messages
  internally.
  """

  @path "/chat/completions"

  @type message :: %{required(String.t()) => term()}

  @doc """
  Make one chat-completion call.

  ## Options
    * `:system`     — system prompt string. Required.
    * `:tools`      — list of tool schemas in MCP catalog shape (the
      `tools/list` result from `MotifMcp`: each tool has `name`,
      `description`, `inputSchema`). Required.
    * `:model`      — model id. Defaults to `:motif_web, :llm_model`.
    * `:max_tokens` — defaults to 2048.
    * `:transport`  — module implementing `MotifWeb.LLM.Transport`.
      Defaults to the live HTTP transport.

  Messages are passed in **content-block form** — our internal,
  vendor-neutral representation using `text` / `tool_use` / `tool_result`
  blocks. The client translates them to OpenAI's flatter `messages` +
  `tool_calls` shape on the wire.
  """
  @spec call(messages :: [message()], keyword()) ::
          {:ok, %{content: list(), stop_reason: String.t() | nil, raw: map()}}
          | {:error, term()}
  def call(messages, opts) when is_list(messages) and is_list(opts) do
    system = Keyword.fetch!(opts, :system)
    tools = Keyword.fetch!(opts, :tools)
    model = Keyword.get(opts, :model, default_model())
    max_tokens = Keyword.get(opts, :max_tokens, 2048)

    body = %{
      "model" => model,
      "max_tokens" => max_tokens,
      "messages" => build_messages(system, messages),
      "tools" => build_tools(tools)
    }

    with {:ok, %{status: 200, body: resp}} <-
           transport(opts).post(base_url() <> @path, body, headers()) do
      {:ok, normalize(resp)}
    else
      {:ok, %{status: status, body: resp}} -> {:error, {:http, status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---- request translation: content blocks → OpenAI messages -------------

  defp build_messages(system, conversation) do
    [%{"role" => "system", "content" => system} | Enum.flat_map(conversation, &to_openai/1)]
  end

  # Simple user text → single user message.
  defp to_openai(%{"role" => "user", "content" => text}) when is_binary(text),
    do: [%{"role" => "user", "content" => text}]

  # A user-role message whose content is a list of blocks: these are our
  # tool_result blocks. OpenAI wants each as its own `role: "tool"` message.
  defp to_openai(%{"role" => "user", "content" => blocks}) when is_list(blocks) do
    Enum.map(blocks, fn
      %{"type" => "tool_result", "tool_use_id" => id, "content" => content} ->
        %{"role" => "tool", "tool_call_id" => id, "content" => stringify_content(content)}
    end)
  end

  # An assistant-role message: split its blocks into a text body + tool_calls.
  defp to_openai(%{"role" => "assistant", "content" => blocks}) when is_list(blocks) do
    text =
      blocks
      |> Enum.filter(&match?(%{"type" => "text"}, &1))
      |> Enum.map_join("", & &1["text"])

    tool_calls =
      for %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} <- blocks do
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => Jason.encode!(input || %{})}
        }
      end

    msg =
      %{"role" => "assistant", "content" => if(text == "", do: nil, else: text)}
      |> maybe_put_tool_calls(tool_calls)

    [msg]
  end

  defp maybe_put_tool_calls(msg, []), do: msg
  defp maybe_put_tool_calls(msg, calls), do: Map.put(msg, "tool_calls", calls)

  defp stringify_content(content) when is_binary(content), do: content

  defp stringify_content([%{"type" => "text", "text" => text} | _]) when is_binary(text),
    do: text

  defp stringify_content(other) when is_binary(other), do: other
  defp stringify_content(other), do: Jason.encode!(other)

  # ---- tool catalog: MCP shape → OpenAI shape ----------------------------

  defp build_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "type" => "function",
        "function" => %{
          "name" => tool["name"],
          "description" => tool["description"],
          "parameters" => tool["inputSchema"] || tool["input_schema"] || %{"type" => "object"}
        }
      }
    end)
  end

  # ---- response translation: OpenAI → content blocks ---------------------

  defp normalize(%{"choices" => [%{"message" => msg, "finish_reason" => finish} | _]} = raw) do
    text =
      case Map.get(msg, "content") do
        nil -> []
        "" -> []
        binary when is_binary(binary) -> [%{"type" => "text", "text" => binary}]
      end

    tool_uses =
      for %{"id" => id, "function" => %{"name" => name, "arguments" => args_json}} <-
            Map.get(msg, "tool_calls", []) || [] do
        %{
          "type" => "tool_use",
          "id" => id,
          "name" => name,
          "input" => decode_args(args_json)
        }
      end

    %{
      content: text ++ tool_uses,
      stop_reason: translate_finish_reason(finish),
      raw: raw
    }
  end

  defp normalize(other), do: %{content: [], stop_reason: nil, raw: other}

  defp decode_args(args) when is_map(args), do: args

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_args(_), do: %{}

  # Translate OpenAI finish_reason values into our internal stop-reason
  # vocabulary (the one the TableLive loop branches on).
  defp translate_finish_reason("tool_calls"), do: "tool_use"
  defp translate_finish_reason("stop"), do: "end_turn"
  defp translate_finish_reason("length"), do: "max_tokens"
  defp translate_finish_reason(other), do: other

  # ---- config ------------------------------------------------------------

  defp headers do
    base = [{"content-type", "application/json"}]

    case Application.fetch_env(:motif_web, :llm_api_key) do
      {:ok, key} when is_binary(key) and key != "" ->
        [{"authorization", "Bearer #{key}"} | base]

      _ ->
        base
    end
  end

  defp base_url, do: Application.fetch_env!(:motif_web, :llm_base_url)

  defp default_model, do: Application.fetch_env!(:motif_web, :llm_model)

  defp transport(opts), do: Keyword.get(opts, :transport, MotifWeb.LLM.HttpTransport)
end
