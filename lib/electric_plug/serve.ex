defmodule ElectricPlug.Serve do
  @moduledoc false
  # The request against a shape the server chose. Electric validates only the tailing
  # parameters — offset, handle, live, cursor — and streams the log; a client's own
  # table, where or columns are ignored, which is the point. A handle the client presents
  # is taken only when it names that shape (`presented/4`).
  #
  # In a cluster (`ElectricPlug.Cluster`) the node that is not serving the stream sends
  # the same request to the one that is, and relays its answer. The shape was decided
  # here, by this node's authorisation; the other node only reads its log.

  alias Electric.Shapes
  alias Electric.Shapes.Shape

  require Logger

  # Beyond Electric's long poll, for the hop and the relay.
  @hop_ms 30_000

  @doc false
  def call(conn, params, shape_params, interrupt \\ nil) do
    case ElectricPlug.Config.resolved() do
      # A node that runs nothing serves nothing: unavailable, and not soon, for it serves
      # only once it is configured and restarted.
      {:disabled, reason} -> disabled(conn, reason)
      _config -> route(conn, params, shape_params, interrupt)
    end
  end

  defp route(conn, params, shape_params, interrupt) do
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
    local(conn, params, shape_params, &predefined/2)
  end

  @doc false
  def local(conn, params, shape_params, predefined_fun) do
    api = ElectricPlug.Config.api()

    case predefined_fun.(api, shape_params) do
      {:ok, shape_api} ->
        respond(shape_api, conn, params)

      # The stack is not ready, or the query names something the database does not
      # have: Electric's own answer, which a client already knows how to retry.
      {:error, %{status: status} = response} ->
        conn
        |> json()
        |> Plug.Conn.send_resp(status, IO.iodata_to_binary(Enum.to_list(response.body || [])))

      {:error, {kind, messages}} when is_atom(kind) ->
        if database_unavailable?(kind) do
          unavailable(conn, plain_message(messages))
        else
          conn
          |> json()
          |> Plug.Conn.send_resp(400, Jason.encode!(%{message: inspect({kind, messages})}))
        end

      {:error, reason} ->
        conn |> json() |> Plug.Conn.send_resp(400, Jason.encode!(%{message: inspect(reason)}))
    end
  end

  defp database_unavailable?(:connection_not_available), do: true

  defp database_unavailable?(kind) do
    name = Atom.to_string(kind)

    unavailable? =
      String.contains?(name, "unavailable") or String.contains?(name, "not_available")

    database? = Enum.any?(["connection", "database", "inspector"], &String.contains?(name, &1))

    unavailable? and database?
  end

  defp plain_message(messages) when is_list(messages) do
    case Enum.map_join(messages, " ", &to_string/1) do
      "" -> "the database is temporarily unavailable"
      message -> message
    end
  end

  defp plain_message(message) when is_binary(message), do: message
  defp plain_message(_message), do: "the database is temporarily unavailable"

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

  defp disabled(conn, reason) do
    message =
      "this node serves no shapes: electric_plug is disabled" <>
        if(reason, do: " (#{reason})", else: "")

    conn
    |> json()
    |> Plug.Conn.put_resp_header("retry-after", "300")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(503, Jason.encode!(%{message: message}))
  end

  defp unavailable(conn, message) do
    conn
    |> json()
    |> Plug.Conn.put_resp_header("retry-after", "1")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(503, Jason.encode!(%{message: message}))
  end

  # Electric's `Shapes.Api.validate/2` is its `validate_params/2` and then its
  # `load_shape_info/1`, which resolves the handle the client presents and seeks in that
  # shape's log. The presented handle is checked between the two, before anything of the
  # shape it names is looked up, listened to or sent.
  defp respond(api, %{method: "GET"} = conn, params) do
    with {:ok, request} <- Shapes.Api.validate_params(api, params),
         shape = request.params.shape_definition,
         :ok <- presented(request, request.params.handle, shape, not request.read_only?),
         {:ok, request} <- Shapes.Api.load_shape_info(request) do
      conn
      |> json()
      |> Plug.Conn.assign(:request, request)
      |> Shapes.Api.serve_shape_log(request)
    else
      {:error, response} -> refuse(conn, response)
    end
  end

  # A delete removes the shape Electric resolved for it: by the shape's definition, or, when
  # the client sends a handle alone, the shape stored under that handle, whichever it is. It
  # is removed only when it is this request's own shape.
  defp respond(api, %{method: "DELETE"} = conn, params) do
    with {:ok, request} <- Shapes.Api.validate_for_delete(api, params),
         :ok <- presented(request, request.handle, api.shape, false) do
      conn |> json() |> Plug.Conn.assign(:request, request) |> Shapes.Api.delete_shape(request)
    else
      {:error, response} -> refuse(conn, response)
    end
  end

  defp respond(_api, %{method: "OPTIONS"} = conn, _params), do: Shapes.Api.options(conn)

  defp respond(_api, conn, _params), do: Plug.Conn.send_resp(conn, 405, "")

  defp refuse(conn, response),
    do: conn |> json() |> Shapes.Api.Response.send(response) |> Plug.Conn.halt()

  # A handle names the log a client is sent. Electric (1.8.1) takes a presented handle when a
  # 27-bit hash (`:erlang.phash2/1`) of the shape stored under it equals the requested shape's
  # (`Electric.ShapeCache.ShapeStatus.validate_shape_handle/3`). That hash covers the where
  # clause, which holds values a client chooses (whose rows, which board), and a handle's text
  # begins with it: a search finds a value whose shape hashes as another person's, and that
  # person's handle, which travels in every URL after her first, then reads her log.
  #
  # So a presented handle is taken only when the shape stored under it is this request's shape,
  # byte for byte as Electric itself tells shapes apart when no handle is presented
  # (`Shape.comparable/1`: the table, its key, the where clause with every value in it, the
  # columns, replica and log mode; its handle lookup keys on a digest of exactly these bytes).
  # Any other handle, or one whose shape is gone, is answered as Electric answers a handle it
  # does not know: 409 must-refetch, with this request's own shape's handle to start over on
  # (made if there is none yet and `make?`). Where the shape under a handle cannot be read,
  # nothing is served on it: 503.
  defp presented(_request, nil, _shape, _make?), do: :ok

  defp presented(request, handle, %Shape{} = shape, make?) when is_binary(handle) do
    case stored(request.api.stack_id, handle) do
      {:ok, stored} ->
        if comparable(stored) == comparable(shape),
          do: :ok,
          else: {:error, must_refetch(request, shape, stored, make?)}

      :error ->
        {:error, must_refetch(request, shape, nil, make?)}

      {:unavailable, reason} ->
        {:error,
         Shapes.Api.Response.error(request, "the shape's handle could not be checked: #{reason}",
           status: 503,
           retry_after: 1
         )}
    end
  end

  # No shape to compare the handle with: it is not served.
  defp presented(request, _handle, _shape, _make?),
    do: {:error, must_refetch(request, nil, nil, false)}

  defp stored(stack_id, handle) do
    case Shapes.fetch_shape_by_handle(stack_id, handle) do
      {:ok, %Shape{} = shape} -> {:ok, shape}
      _ -> :error
    end
  rescue
    error -> {:unavailable, Exception.message(error)}
  catch
    :exit, _reason -> {:unavailable, "the shape store did not answer"}
  end

  defp comparable(shape),
    do: shape |> Shape.comparable() |> :erlang.term_to_binary([:deterministic])

  defp must_refetch(request, shape, stored, make?) do
    if stored && Shape.hash(stored) == Shape.hash(shape) do
      # Not a shape whose definition has since changed: another shape, whose hash Electric
      # cannot tell from this one's, was asked for by its handle.
      Logger.warning(
        "electric_plug: refused a presented handle whose shape (#{inspect(stored.root_table)}) " <>
          "hashes as the requested shape's (#{inspect(shape.root_table)}) but is another shape"
      )
    end

    error = Shapes.Api.Error.must_refetch()

    Shapes.Api.Response.error(request, error.message,
      handle: own_handle(request.api.stack_id, shape, make?),
      status: error.status
    )
  end

  # This request's own shape's handle, as Electric's own must-refetch gives one. None when it
  # cannot be had: the client then starts over without one.
  defp own_handle(_stack_id, nil, _make?), do: nil

  defp own_handle(stack_id, shape, make?) do
    case {Shapes.fetch_handle_by_shape(stack_id, shape), make?} do
      {{:ok, handle}, _make?} ->
        handle

      {:error, true} ->
        case Shapes.get_or_create_shape_handle(stack_id, shape) do
          {handle, _offset} when is_binary(handle) -> handle
          _ -> nil
        end

      {:error, false} ->
        nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp json(conn), do: Plug.Conn.put_resp_content_type(conn, "application/json")
end
