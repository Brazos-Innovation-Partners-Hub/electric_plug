defmodule ElectricHost.Router do
  @moduledoc """
  The application's routes: `GET /shapes/todos`, for the person the `x-actor` header names
  (standing in for a sign-in).
  """
  use Plug.Router

  plug :match
  plug :fetch_query_params
  plug :dispatch

  get "/shapes/todos" do
    case get_req_header(conn, "x-actor") do
      [name] when name != "" -> ElectricHost.TodoShapes.show(conn, conn.query_params, name)
      _ -> send_resp(conn, 401, "who is asking?")
    end
  end

  match _ do
    send_resp(conn, 404, "")
  end
end
