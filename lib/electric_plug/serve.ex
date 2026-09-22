defmodule ElectricPlug.Serve do
  @moduledoc false
  # The request against a shape the server chose. Electric validates only the tailing
  # parameters — offset, handle, live, cursor — and streams the log; a client's own
  # table, where or columns are ignored, which is the point.

  alias Electric.Shapes

  @doc false
  def call(conn, params, shape_params) do
    api = ElectricPlug.Config.api()

    case Shapes.Api.predefined_shape(api, shape_params) do
      {:ok, shape_api} ->
        respond(shape_api, conn, params)

      # The stack is not ready, or the query names something the database does not
      # have: Electric's own answer, which a client already knows how to retry.
      {:error, %{status: status} = response} ->
        conn
        |> json()
        |> Plug.Conn.send_resp(status, IO.iodata_to_binary(Enum.to_list(response.body || [])))

      {:error, reason} ->
        conn |> json() |> Plug.Conn.send_resp(400, Jason.encode!(%{message: inspect(reason)}))
    end
  end

  defp respond(api, %{method: "GET"} = conn, params) do
    case Shapes.Api.validate(api, params) do
      {:ok, request} ->
        conn
        |> json()
        |> Plug.Conn.assign(:request, request)
        |> Shapes.Api.serve_shape_log(request)

      {:error, response} ->
        conn |> json() |> Shapes.Api.Response.send(response) |> Plug.Conn.halt()
    end
  end

  defp respond(api, %{method: "DELETE"} = conn, params) do
    case Shapes.Api.validate_for_delete(api, params) do
      {:ok, request} ->
        conn |> json() |> Plug.Conn.assign(:request, request) |> Shapes.Api.delete_shape(request)

      {:error, response} ->
        conn |> json() |> Shapes.Api.Response.send(response) |> Plug.Conn.halt()
    end
  end

  defp respond(_api, %{method: "OPTIONS"} = conn, _params), do: Shapes.Api.options(conn)

  defp respond(_api, conn, _params), do: Plug.Conn.send_resp(conn, 405, "")

  defp json(conn), do: Plug.Conn.put_resp_content_type(conn, "application/json")
end
