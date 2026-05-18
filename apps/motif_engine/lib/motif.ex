defmodule Motif do
  @moduledoc """
  Top-level convenience facade for the engine. The engine itself lives
  under `MotifEngine.*`; this module exists so quick iex sessions can
  reach common operations without remembering app-name prefixes.
  """

  defdelegate ping, to: MotifEngine.Repo
  defdelegate start_game(rules_module, opts), to: MotifEngine
  defdelegate submit_intent(game_id, intent), to: MotifEngine
  defdelegate legal_actions(game_id, player_id), to: MotifEngine
end
