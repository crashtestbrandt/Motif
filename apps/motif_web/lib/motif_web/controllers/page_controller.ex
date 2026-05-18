defmodule MotifWeb.PageController do
  use MotifWeb, :controller

  def home(conn, _params) do
    text(conn, """
    motif — Clue prototype

    To start a game and get player URLs, run:
        mix motif.demo_chat

    Then open the printed URLs in two browser tabs.
    """)
  end
end
