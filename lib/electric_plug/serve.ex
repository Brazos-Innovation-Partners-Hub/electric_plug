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
  def call(conn, params, shape_params, interrupt \\ nil) do
    # Only a long poll waits, so only a long poll can be interrupted.
    interrupt = if live?(params), do: interrupt

    case ElectricPlug.Cluster.route() do
      :local ->
        # In a cluster the active node serves its own requests the way it serves a
        # forwarded one: watched against its tenure (`ElectricPlug.Remote`); and so does
        # any node a request that may be interrupted.
        if conn.method != "OPTIONS" and (ElectricPlug.Cluster.enabled?() or interrupt != nil),
          do:
            relay(
              conn,
              ElectricPlug.Remote.serve(
                conn.method,
                params,
                shape_params,
                headers(conn),
                interrupt
              )
            ),
          else: local(conn, params, shape_params)

      {:remote, node} ->
        forward(conn, node, params, shape_params, interrupt)

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

    case predefined(api, shape_params) do
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

  # A migration that adds a column while Electric runs leaves Electric's inspector
  # describing the table as it was, and it learns otherwise only from a change to a table
  # a shape already reads — so a shape asking for the new column is refused, no shape is
  # made, and nothing ever tells it: every request fails until someone deletes the
  # persisted cache by hand (the patchnotes-web lane, 2026-09-23). Refused for a column or
  # a where it does not know, the relation is forgotten and the shape asked for once more.
  defp predefined(api, shape_params) do
    case Shapes.Api.predefined_shape(api, shape_params) do
      {:error, {kind, _messages}} = refused when kind in [:columns, :where] ->
        if forget_relation(api, shape_params),
          do: Shapes.Api.predefined_shape(api, shape_params),
          else: refused

      answer ->
        answer
    end
  end

  defp forget_relation(api, shape_params) do
    schema = shape_params[:namespace] || shape_params[:schema] || "public"

    case Electric.Postgres.Inspector.load_relation_oid(
           {schema, shape_params[:table]},
           api.inspector
         ) do
      {:ok, {oid, _relation}} -> Electric.Postgres.Inspector.clean(oid, api.inspector) == :ok
      _other -> false
    end
  rescue
    # Said, not swallowed: a quiet failure here is a shape refused for ever again.
    error ->
      require Logger

      Logger.warning(
        "electric_plug: could not refresh #{inspect(shape_params[:table])}: #{Exception.message(error)}"
      )

      false
  end

  defp live?(params), do: Map.get(params, "live") in ["true", true]

  defp forward(%{method: "OPTIONS"} = conn, _node, params, shape_params, _interrupt),
    do: local(conn, params, shape_params)

  defp forward(conn, node, params, shape_params, interrupt) do
    timeout = Keyword.get(ElectricPlug.Config.electric(), :long_poll_timeout, 20_000) + @hop_ms

    hop = fn ->
      :erpc.call(
        node,
        ElectricPlug.Remote,
        :serve,
        [conn.method, params, shape_params, headers(conn)],
        timeout
      )
    end

    relay(conn, if(interrupt, do: ElectricPlug.Remote.watch(hop, nil, interrupt), else: hop.()))
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
