defmodule ElectricPlug do
  @moduledoc """
  Serves Electric's shape-log protocol for an authorised Ecto query, with Electric
  embedded in the application.

  It is the thin part of `phoenix_sync` — the part an application that already decides
  *what* a client may sync needs — and nothing else: no HTTP proxy mode, no installer,
  no writer, no sandbox. The query is the whole contract: build it however your
  authorisation works, and a client gets exactly its rows, live.

  ## Configuration

      config :electric_plug,
        env: config_env(),
        repo: MyApp.Repo,
        # everything else is Electric's own configuration:
        replication_stream_id: "my_app",
        db_pool_size: 4

  `repo`'s connection configuration becomes Electric's replication connection. Instead of
  a repo you may give `connection_opts:`. `mode: :disabled` starts nothing, for a test
  that needs no database.

  Per environment, without being asked: in `:test` a stack id, a temporary replication
  slot, in-memory shape logs and a fresh `storage_dir` per run — the shape status
  Electric keeps on disk must not outlive logs kept in memory; in `:dev` a `storage_dir`
  under the system's temporary directory; in `:prod` what you configured.

  ## Serving

      def show(conn, params) do
        query = from(t in Todo, where: t.owner_id == ^conn.assigns.current_user.id)
        ElectricPlug.serve(conn, params, query)
      end

  `serve/4` takes the request's params (`offset`, `handle`, `live`, `cursor`), builds the
  shape from the query, and streams the log. A client cannot widen the shape: `table`,
  `where` and `columns` in the request are ignored. Options: `replica: :full` to send
  whole rows on update, `columns:` to narrow.

  The Electric stack is started by this library's application when configured, so an
  application adds nothing to its supervision tree. `children/0` returns the same child
  specs for an application that wants to place them itself (set `start: false`).

  ## Several nodes

  `cluster: true` runs one Electric for the stream across connected nodes, any of which
  answers a shape request — see `ElectricPlug.Cluster`. Production also makes Electric's
  slot ahead of Electric, failover-capable where the server supports it, and
  `mix electric_plug.slots` lists, and drops, the slots nothing reads — see
  `ElectricPlug.Slots`.
  """

  alias ElectricPlug.{Config, Shape, Serve}

  @doc "The Electric stack's child specs, from the configuration. `[]` when disabled."
  @spec children() :: [Supervisor.child_spec() | {module(), term()}]
  def children, do: Config.children()

  @doc "The configured `Electric.Shapes.Api`, for anything that wants to drive Electric directly."
  @spec api() :: Electric.Shapes.Api.t()
  def api, do: Config.api()

  @doc """
  Serves the shape log for `queryable` — a schema module or an `Ecto.Query` — to `conn`.

  Options: `replica: :default | :full`, `columns: [String.t()]`, and `interrupt:` — a
  message this process may be sent while a live request waits (a long poll parks for up
  to twenty seconds). When it arrives the request is answered at once, 403, instead of
  streaming on: how a host ends the access of an actor being ejected rather than waiting
  for their next request to be refused. The caller arranges for the message to come (a
  PubSub subscription, say); nothing is subscribed here.
  """
  @spec serve(Plug.Conn.t(), map(), term(), keyword()) :: Plug.Conn.t()
  def serve(conn, params, queryable, opts \\ []) do
    {interrupt, opts} = Keyword.pop(opts, :interrupt)
    Serve.call(conn, params, Shape.params(queryable, opts), interrupt)
  end

  @doc """
  Whether this node can answer a shape request, and how: `:active` (its own stack serves
  the stream), `{:forwarding, node}` (a clustered node forwards to the one that does), or
  `:unavailable`. For readiness checks.
  """
  @spec serving() :: :active | {:forwarding, node()} | :unavailable
  def serving do
    case ElectricPlug.Cluster.route() do
      :local -> if ready?(), do: :active, else: :unavailable
      {:remote, node} -> {:forwarding, node}
      :none -> :unavailable
    end
  end

  @doc "Whether the embedded stack is up and serving. For readiness checks."
  @spec ready?() :: boolean()
  def ready?, do: Config.ready?()

  @doc "Blocks until the stack is serving, or errors after `timeout` ms. For a test helper."
  @spec await_ready(pos_integer()) :: :ok | {:error, term()}
  def await_ready(timeout \\ 60_000), do: Config.await_ready(timeout)
end
