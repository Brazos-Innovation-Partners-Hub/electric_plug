defmodule ElectricPlug.Serve do
  @moduledoc false
  # The request against a shape the server chose. Electric validates only the tailing
  # parameters — offset, handle, live, cursor — and streams the log; a client's own
  # table, where or columns are ignored, which is the point.
  #
  # In a cluster (`ElectricPlug.Cluster`) the node that is not serving the stream sends
  # the same request to the one that is, and relays its answer. The shape was decided
  # here, by this node's authorisation; the other node only reads its log.

  alias Electric.Shapes

  # Beyond Electric's long poll, for the hop and the relay.
  @hop_ms 30_000

  @doc false
  def call(conn, params, shape_params) do
    case ElectricPlug.Cluster.route() do
      :local ->
        # In a cluster the active node serves its own requests the way it serves a
        # forwarded one: watched against its tenure (`ElectricPlug.Remote`).
        if ElectricPlug.Cluster.enabled?() and conn.method != "OPTIONS",
          do:
            relay(
              conn,
              ElectricPlug.Remote.serve(conn.method, params, shape_params, headers(conn))
            ),
          else: local(conn, params, shape_params)

      {:remote, node} ->
        forward(conn, node, params, shape_params)

      :none ->
        unavailable(conn, "no node is serving shapes yet")
    end
  end

  defp headers(conn),
    do: Enum.filter(conn.req_headers, fn {name, _} -> name == "if-none-match" end)

  defp relay(conn, {status, resp_headers, body}) do
    conn
    |> Plug.Conn.merge_resp_headers(resp_headers)
    |> Plug.Conn.send_resp(status, body)
  end

  @doc false
  def local(conn, params, shape_params) do
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

  defp forward(%{method: "OPTIONS"} = conn, _node, params, shape_params),
    do: local(conn, params, shape_params)

  defp forward(conn, node, params, shape_params) do
    timeout = Keyword.get(ElectricPlug.Config.electric(), :long_poll_timeout, 20_000) + @hop_ms

    relay(
      conn,
      :erpc.call(
        node,
        ElectricPlug.Remote,
        :serve,
        [conn.method, params, shape_params, headers(conn)],
        timeout
      )
    )
  rescue
    # The serving node went away mid-request, or is not a node any more: the client's
    # retry lands on whoever serves next.
    error ->
      unavailable(conn, "the node serving shapes did not answer: #{Exception.message(error)}")
  catch
    kind, reason ->
      unavailable(conn, "the node serving shapes did not answer: #{inspect({kind, reason})}")
  end

  defp unavailable(conn, message) do
    conn
    |> json()
    |> Plug.Conn.put_resp_header("retry-after", "1")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(503, Jason.encode!(%{message: message}))
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
