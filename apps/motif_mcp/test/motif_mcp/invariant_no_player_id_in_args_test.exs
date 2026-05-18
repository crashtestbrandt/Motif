defmodule MotifMcp.InvariantNoPlayerIdInArgsTest do
  @moduledoc """
  ADR-0009: no MCP tool handler is allowed to read `player_id` from
  the `args` parameter — it must come from the session-bound `ctx`
  (first arg to `handle/2`).

  Static check. We parse each tool module's source, locate every
  `def handle(_ctx, args_pat) do body end` clause, then check:

    1. `args_pat` does not contain a `player_id` *match key* (either
       `%{"player_id" => _}` or `%{player_id: _}`).
    2. `body` does not perform a *read* of player_id from any binding:
       no `<expr>["player_id"]`, no `<expr>[:player_id]`, no
       `<expr>.player_id`.

  Setting `player_id: pid` into a map is fine — that's writing a key,
  not reading from args. The check distinguishes by position in the
  AST.
  """

  use ExUnit.Case, async: true

  @tool_files Path.wildcard(
                Path.expand("../../lib/motif_mcp/tools/*.ex", __DIR__)
              )

  test "the test discovers tool files" do
    assert length(@tool_files) >= 5,
           "expected at least 5 tool files, found: #{inspect(@tool_files)}"
  end

  for path <- @tool_files do
    @path path
    test "tool module #{Path.basename(@path)} does not read player_id from args" do
      source = File.read!(@path)
      ast = Code.string_to_quoted!(source)
      violations = collect_violations(ast)

      assert violations == [],
             """
             ADR-0009 violation in #{@path}:
             #{Enum.map_join(violations, "\n", &"  - #{&1}")}

             A tool handler must read `player_id` from the first argument
             (the session-bound ctx). The args parameter and handler body
             must not pattern-match on or read `player_id`.
             """
    end
  end

  describe "the check itself" do
    test "catches body that reads args[\"player_id\"]" do
      ast =
        Code.string_to_quoted!("""
        defmodule Bad do
          def handle(_ctx, args), do: args["player_id"]
        end
        """)

      assert "body reads player_id via access/dot" in collect_violations(ast)
    end

    test "catches body that reads args[:player_id]" do
      ast =
        Code.string_to_quoted!("""
        defmodule Bad do
          def handle(_ctx, args), do: args[:player_id]
        end
        """)

      assert "body reads player_id via access/dot" in collect_violations(ast)
    end

    test "catches args pattern with player_id key" do
      ast =
        Code.string_to_quoted!("""
        defmodule Bad do
          def handle(_ctx, %{"player_id" => pid}), do: pid
        end
        """)

      assert "args pattern matches on player_id" in collect_violations(ast)
    end

    test "permits writing player_id as a map key (binding from ctx)" do
      ast =
        Code.string_to_quoted!("""
        defmodule Good do
          def handle(%{player_id: pid}, _args), do: %{player_id: pid, type: :foo}
        end
        """)

      assert collect_violations(ast) == []
    end
  end

  defp collect_violations(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{:handle, _, [_ctx, args_pat]}, [{:do, body}]]} = node, acc ->
          {node, check_clause(args_pat, body, acc)}

        {:def, _, [{:handle, _, [_ctx, args_pat]}, kw]} = node, acc when is_list(kw) ->
          body = Keyword.get(kw, :do)
          {node, check_clause(args_pat, body, acc)}

        other, acc ->
          {other, acc}
      end)

    Enum.uniq(acc)
  end

  defp check_clause(args_pat, body, acc) do
    acc
    |> maybe_add("args pattern matches on player_id", pattern_matches_player_id?(args_pat))
    |> maybe_add("body reads player_id via access/dot", body_reads_player_id?(body))
  end

  defp maybe_add(acc, _, false), do: acc
  defp maybe_add(acc, label, true), do: [label | acc]

  # A pattern matches on player_id if it's a map literal whose keys
  # contain the atom :player_id or string "player_id". (Other map keys
  # are fine; we're only flagging this one.)
  defp pattern_matches_player_id?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:%{}, _, pairs} = node, acc ->
          {node, acc or Enum.any?(pairs, &player_id_key?/1)}

        other, acc ->
          {other, acc}
      end)

    found?
  end

  defp player_id_key?({:player_id, _}), do: true
  defp player_id_key?({"player_id", _}), do: true
  defp player_id_key?(_), do: false

  # A body "reads" player_id via:
  #   <expr>[:player_id]          → Access.get(<expr>, :player_id)
  #   <expr>["player_id"]         → Access.get(<expr>, "player_id")
  #   <expr>.player_id            → ({:., _, [<expr>, :player_id]}, _, [])
  #
  # Setting `:player_id => v` into a map literal is NOT a read.
  defp body_reads_player_id?(nil), do: false

  defp body_reads_player_id?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        # Access.get(_, :player_id) or (_, "player_id")
        {{:., _, [Access, :get]}, _, [_subj, key]} = node, acc ->
          {node, acc or key == :player_id or key == "player_id"}

        # <expr>.player_id — field access via the dot tuple form.
        {{:., _, [_subj, :player_id]}, _, []} = node, _acc ->
          {node, true}

        other, acc ->
          {other, acc}
      end)

    found?
  end
end
