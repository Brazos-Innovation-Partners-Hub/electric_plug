defmodule ElectricPlug do
  @moduledoc """
  Serves Electric's shape-log protocol for an authorised Ecto query, with Electric
  embedded in the application.

  It is the thin part of `phoenix_sync` — the part an application that already decides
  *what* a client may sync needs — and nothing else: no HTTP proxy mode, no installer,
  no writer, no sandbox. The query is the whole contract: build it however your
  authorisation works, and a client gets exactly its rows and columns, live, and nothing
  wider.

  ## Serving

      def show(conn, params) do
        query = from(t in Todo, where: t.owner_id == ^conn.assigns.current_user.id)
        ElectricPlug.serve(conn, params, query)
      end

  `serve/4` is this module's one function, so a module that calls `ElectricPlug` is one that
  serves shapes, and the rules this library ships to its hosts (`ElectricPlug.Meaning`) ask
  each such module to name, in its effects, the Ash read its query comes from, and that read
  to be decided by its resource's policies.

  It takes the request's params (`offset`, `handle`, `live`, `cursor`), builds the shape from
  the query (`ElectricPlug.Shape`), and streams the log. A client cannot widen the shape:
  `table`, `where` and `columns` in the request are ignored. Options: `replica: :full` to send
  whole rows on update, `columns:` to narrow the query's columns (never to widen them), and
  `interrupt:` to end a waiting request.

  ## Configuration

      config :electric_plug,
        env: config_env(),
        repo: MyApp.Repo,
        replication_stream_id: "my_app",
        # Electric's own options, given to Electric as they are:
        electric: [db_pool_size: 4]

  `repo`'s connection configuration becomes Electric's replication connection. Instead of a
  repo you may give `connection_opts:`; it accepts the output of
  `Electric.Config.parse_postgresql_uri!/1` as well. `mode: :disabled` starts nothing, and
  every shape request is answered 503; `mode: :forward` starts nothing either: that node
  answers every shape request by sending it to the node of its cluster that serves
  `replication_stream_id`. Every key is declared, with what it controls, in
  `ElectricPlug.Design`.

  Per environment, without being asked: in `:test` a stack id, a temporary replication
  slot, in-memory shape logs and a fresh `storage_dir` per run — the shape status
  Electric keeps on disk must not outlive logs kept in memory; in `:dev` a `storage_dir`
  under the system's temporary directory; in `:prod` what you configured.

  The Electric stack is started by this library's application when configured, so an
  application adds nothing to its supervision tree. `ElectricPlug.Node.children/0` returns the
  same child specs for an application that wants to place them itself (set `start: false`),
  and `ElectricPlug.Node` says what this node runs and whether it serves.

  ## Several nodes

  `cluster: true` runs one Electric for the stream across connected nodes, any of which
  answers a shape request — see `ElectricPlug.Cluster`. A node with `mode: :forward` joins
  in without running Electric, for nodes that serve requests but must not read the stream
  themselves (no direct connection to the primary, no storage of their own). Production also
  makes Electric's slot ahead of Electric, failover-capable where the server supports it,
  and `mix electric_plug.slots` lists, and drops, the slots nothing reads — see
  `ElectricPlug.Slots`.
  """

  alias ElectricPlug.{Serve, Shape}

  @doc """
  Serves the shape log for `queryable` — a schema module or an `Ecto.Query` — to `conn`.

  Options: `replica: :default | :full`, `columns: [String.t()]` (a narrower list of the query's
  own columns), and `interrupt:` — a message this process may be sent while a live request
  waits (a long poll parks for up to twenty seconds). When it arrives the request is answered
  at once, 403, instead of streaming on: how a host ends the access of an actor being ejected
  rather than waiting for their next request to be refused. The caller arranges for the
  message to come (a PubSub subscription, say); nothing is subscribed here.

  A node that runs nothing (`mode: :disabled`) answers 503. An option that would widen the
  query (a column it does not select, a `where:` beside it) or a query that cannot be one shape
  raises `ArgumentError`: a host's mistake, refused before anything is served.
  """
  @spec serve(Plug.Conn.t(), map(), Ecto.Queryable.t(), keyword()) :: Plug.Conn.t()
  def serve(conn, params, queryable, opts \\ []) do
    {interrupt, opts} = Keyword.pop(opts, :interrupt)

    case Shape.params(queryable, opts) do
      {:ok, shape_params} -> Serve.call(conn, params, shape_params, interrupt)
      {:error, reason} -> raise ArgumentError, "electric_plug: #{reason}"
    end
  end
end
