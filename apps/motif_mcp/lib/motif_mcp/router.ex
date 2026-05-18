defmodule MotifMcp.Router do
  @moduledoc """
  HTTP entry point. Two routes only:

    * `POST /sessions` — body `{"token": "..."}`. Returns a session id.
    * `POST /sessions/:id/rpc` — body is a JSON-RPC 2.0 request.

  Session id is the only credential after handshake. `player_id` is
  stamped on session open from the token's bound identity (ADR-0009)
  and never read from request bodies.
  """

  use Plug.Router

  alias MotifMcp.{JsonRpc, SessionManager}

  plug :match
  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :dispatch

  # ---- sessions ----------------------------------------------------------

  post "/sessions" do
    with %{"token" => token} when is_binary(token) <- conn.body_params,
         {:ok, session_id, _ctx} <- SessionManager.open(token) do
      send_json(conn, 201, %{"session_id" => session_id})
    else
      {:error, :invalid_token} ->
        send_json(conn, 401, %{"error" => "invalid_token"})

      _ ->
        send_json(conn, 400, %{"error" => "missing_or_invalid_token"})
    end
  end

  # ---- JSON-RPC ----------------------------------------------------------

  post "/sessions/:session_id/rpc" do
    case SessionManager.lookup(session_id) do
      {:ok, ctx} ->
        # The request body has already been parsed by Plug.Parsers; Plug
        # surfaces the parse error as a Plug.Parsers.ParseError before we
        # reach here, so by the time we're in this handler the body is a
        # valid JSON map. Dispatch.
        response = JsonRpc.handle(ctx, conn.body_params)
        send_json(conn, 200, response)

      :error ->
        send_json(conn, 404, %{"error" => "session_not_found"})
    end
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
