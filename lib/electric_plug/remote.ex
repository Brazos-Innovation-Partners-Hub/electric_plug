defmodule ElectricPlug.Remote do
  @moduledoc false
  # A shape request served against this node's stack into a connection that keeps what it
  # is sent, and returned whole — status, headers, body. The serving node's half of a
  # forwarded request (`ElectricPlug.Cluster`), and in a cluster how the active node
  # serves its own requests too.
  #
  # In a cluster the request runs in a process of its own, watched against the node's
  # tenure: a tenure ends when the stack loses the stream (a failover, a lost lock), the
  # stack is restarted, and a long poll waiting on the old stack's shapes would otherwise
  # wait out its whole twenty seconds for a change that can no longer come. It is answered
  # at once instead — 503, retry in a second — and the client's retry finds whoever
  # serves now.

  @doc false
  def serve(method, params, shape_params, req_headers, interrupt \\ nil) do
    serve = fn -> capture(method, params, shape_params, req_headers) end

    case {Process.whereis(ElectricPlug.Cluster), interrupt} do
      {nil, nil} -> serve.()
      {tenure, interrupt} -> watch(serve, tenure, interrupt)
    end
  end

  # A request answered by `serve`, run in a process of its own and watched: against the
  # node's tenure (`nil`: none), and for `interrupt`, a message this process may be sent
  # (`nil`: none). Either answers at once and ends the request's process.
  @doc false
  def watch(serve, tenure, interrupt) do
    parent = self()
    tag = make_ref()
    tenure_ref = tenure && Process.monitor(tenure)

    {pid, ref} = spawn_monitor(fn -> send(parent, {tag, serve.()}) end)

    receive do
      {^tag, result} ->
        Process.demonitor(ref, [:flush])
        if tenure_ref, do: Process.demonitor(tenure_ref, [:flush])
        result

      {:DOWN, ^tenure_ref, :process, _, _} when tenure_ref != nil ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        unavailable("the node serving this shape stopped serving the stream")

      {:DOWN, ^ref, :process, _, reason} ->
        if tenure_ref, do: Process.demonitor(tenure_ref, [:flush])
        unavailable("serving the shape failed: #{inspect(reason)}")

      message when interrupt != nil and message == interrupt ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        if tenure_ref, do: Process.demonitor(tenure_ref, [:flush])
        ended()
    end
  end

  # Access to the shape has ended while a long poll waited on it: refused, and not to be
  # asked again as if nothing had happened.
  defp ended do
    {403,
     [
       {"content-type", "application/json; charset=utf-8"},
       {"cache-control", "no-store"}
     ], Jason.encode!(%{message: "access to this shape has ended"})}
  end

  defp unavailable(message) do
    {503,
     [
       {"content-type", "application/json; charset=utf-8"},
       {"retry-after", "1"},
       {"cache-control", "no-store"}
     ], Jason.encode!(%{message: message})}
  end

  defp capture(method, params, shape_params, req_headers) do
    conn =
      %Plug.Conn{
        adapter: {__MODULE__.Capture, %{chunks: []}},
        method: method,
        owner: self(),
        req_headers: req_headers,
        params: params,
        query_params: params,
        body_params: %{},
        path_params: %{}
      }
      |> ElectricPlug.Serve.local(params, shape_params)

    {_adapter, %{chunks: chunks}} = conn.adapter
    body = IO.iodata_to_binary([conn.resp_body || "" | Enum.reverse(chunks)])
    {conn.status, conn.resp_headers, body}
  end
end

defmodule ElectricPlug.Remote.Capture do
  @moduledoc false
  # A Plug adapter that sends nothing anywhere: what is sent is kept in its state.
  @behaviour Plug.Conn.Adapter

  @impl true
  def send_resp(state, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), state}

  @impl true
  def send_file(state, _status, _headers, path, offset, length) do
    body = File.read!(path)
    length = if length == :all, do: byte_size(body) - offset, else: length
    {:ok, binary_part(body, offset, length), state}
  end

  @impl true
  def send_chunked(state, _status, _headers), do: {:ok, nil, state}

  @impl true
  def chunk(state, body), do: {:ok, nil, %{state | chunks: [body | state.chunks]}}

  @impl true
  def read_req_body(state, _opts), do: {:ok, "", state}

  @impl true
  def inform(_state, _status, _headers), do: {:error, :not_supported}

  @impl true
  def upgrade(_state, _protocol, _opts), do: {:error, :not_supported}

  @impl true
  def push(_state, _path, _headers), do: {:error, :not_supported}

  @impl true
  def get_peer_data(_state), do: %{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil}

  @impl true
  def get_http_protocol(_state), do: :"HTTP/1.1"

  @impl true
  def get_sock_data(_state), do: %{address: {127, 0, 0, 1}, port: 0}

  @impl true
  def get_ssl_data(_state), do: nil
end
