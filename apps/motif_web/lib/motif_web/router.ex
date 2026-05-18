defmodule MotifWeb.Router do
  use MotifWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {MotifWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", MotifWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/play/:game_id/:player_id", TableLive
  end
end
