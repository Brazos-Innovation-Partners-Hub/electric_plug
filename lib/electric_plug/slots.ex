defmodule ElectricPlug.Slots do
  @moduledoc """
  Electric's replication slots, looked after.

  A logical replication slot keeps every byte of WAL written after its position until
  someone reads it. Electric reads its own; but a slot nobody reads any more — a node
  removed from a cluster with its own stream id, a stream id changed in a deploy, an
  instance that crashed with a persistent slot and never came back — keeps WAL until it is
  dropped, and on a database whose disk is sized for its data that fills the disk.

  So this module does three things, each small:

    * `list/1` — every logical slot, with whether something is reading it and how much WAL
      it is holding back;
    * `ensure/3` — makes Electric's slot before Electric does, marked `failover` where the
      server supports it (PostgreSQL 17+), so that a standby promoted by Patroni or a
      managed failover has the slot too and Electric resumes rather than starting over.
      Electric reuses a slot that exists; creating it first is how the flag gets set;
    * `orphans/2` and `drop/2` — the slots no running stream owns, and dropping one, which
      refuses a slot something is reading.

  Every function takes Postgrex connection options (`ElectricPlug.Config` has the
  application's) or a started Postgrex connection.
  """

  @type conn :: pid() | keyword()

  @doc """
  Every logical replication slot: `name`, `active?`, `failover?`, `retained_bytes` (WAL
  held back since the slot's restart position), and `plugin`.
  """
  @spec list(conn()) :: {:ok, [map()]} | {:error, term()}
  def list(conn) do
    with_connection(conn, fn pid ->
      failover = if version(pid) >= 170_000, do: "failover", else: "false"

      sql = """
      select slot_name, active, #{failover}, plugin,
             coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), 0)::bigint
      from pg_replication_slots
      where slot_type = 'logical'
      order by slot_name
      """

      case Postgrex.query(pid, sql, []) do
        {:ok, %{rows: rows}} ->
          {:ok,
           Enum.map(rows, fn [name, active, failover, plugin, retained] ->
             %{
               name: name,
               active?: active,
               failover?: failover == true,
               plugin: plugin,
               retained_bytes: retained
             }
           end)}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  @doc """
  Makes the slot `name` for Electric if it does not exist: logical, `pgoutput`, and
  `failover` when `:failover` is `true`, or `:auto` (the default) and the server is 17 or
  later. Returns `{:ok, :created}` or `{:ok, :exists}`; one of several nodes racing to
  make the same slot gets `:exists`. Making a logical slot waits for every transaction open
  on the server to end; `:timeout` (default 60 s) bounds the wait.

  With `publication: name`, the publication Electric reads through is made first when it
  is missing, the way Electric makes it (empty; Electric adds tables). Electric drops and
  remakes a slot older than its publication — one made before it cannot decode through it
  (electric-sql/electric#2692) — so a slot made ahead without its publication would be
  replaced, failover flag and all, the moment Electric started. An idle slot found without
  its publication is dropped here for the same reason, and made again after it.
  """
  @spec ensure(conn(), String.t(), keyword()) :: {:ok, :created | :exists} | {:error, term()}
  def ensure(conn, name, opts \\ []) when is_binary(name) do
    with_connection(
      conn,
      fn pid ->
        with :ok <- ensure_publication(pid, name, Keyword.get(opts, :publication)) do
          ensure_slot(pid, name, opts)
        end
      end,
      Keyword.get(opts, :timeout, 60_000) + 10_000
    )
  end

  defp ensure_publication(_pid, _slot, nil), do: :ok

  defp ensure_publication(pid, slot, publication) do
    case Postgrex.query(pid, "select 1 from pg_publication where pubname = $1", [publication]) do
      {:ok, %{rows: [_]}} ->
        :ok

      {:ok, %{rows: []}} ->
        generated =
          if version(pid) >= 180_000, do: " WITH (publish_generated_columns = stored)", else: ""

        with {:ok, _} <-
               Postgrex.query(
                 pid,
                 "CREATE PUBLICATION #{quote_ident(publication)}#{generated}",
                 []
               ) do
          case Postgrex.query(
                 pid,
                 "select active from pg_replication_slots where slot_name = $1",
                 [slot]
               ) do
            {:ok, %{rows: [[false]]}} ->
              with {:ok, _} <- Postgrex.query(pid, "select pg_drop_replication_slot($1)", [slot]),
                   do: :ok

            {:ok, _} ->
              :ok

            error ->
              error
          end
        else
          {:error, %Postgrex.Error{postgres: %{code: :duplicate_object}}} -> :ok
          error -> error
        end

      error ->
        error
    end
  end

  defp ensure_slot(pid, name, opts) do
    if exists?(pid, name) do
      {:ok, :exists}
    else
      failover =
        case Keyword.get(opts, :failover, :auto) do
          :auto -> version(pid) >= 170_000
          flag -> flag == true
        end

      sql =
        if failover,
          do: "select pg_create_logical_replication_slot($1, 'pgoutput', false, false, true)",
          else: "select pg_create_logical_replication_slot($1, 'pgoutput')"

      case Postgrex.query(pid, sql, [name], timeout: Keyword.get(opts, :timeout, 60_000)) do
        {:ok, _} -> {:ok, :created}
        {:error, %Postgrex.Error{postgres: %{code: :duplicate_object}}} -> {:ok, :exists}
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc """
  Logical slots that look like Electric's (`electric_slot_` by default) and are neither
  being read nor in `keep` — a cluster's own stream's slot must be named there, or it is
  an orphan between restarts. The caller decides what to drop.
  """
  @spec orphans(conn(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def orphans(conn, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "electric_slot_")
    keep = Keyword.get(opts, :keep, [])

    with {:ok, slots} <- list(conn) do
      {:ok,
       Enum.filter(slots, fn slot ->
         String.starts_with?(slot.name, prefix) and not slot.active? and slot.name not in keep
       end)}
    end
  end

  @doc "Drops the slot `name`. Refuses a slot something is reading."
  @spec drop(conn(), String.t()) :: :ok | {:error, :active | :missing | term()}
  def drop(conn, name) when is_binary(name) do
    with_connection(conn, fn pid ->
      case Postgrex.query(pid, "select active from pg_replication_slots where slot_name = $1", [
             name
           ]) do
        {:ok, %{rows: [[true]]}} ->
          {:error, :active}

        {:ok, %{rows: [[false]]}} ->
          case Postgrex.query(pid, "select pg_drop_replication_slot($1)", [name]) do
            {:ok, _} -> :ok
            {:error, error} -> {:error, error}
          end

        {:ok, %{rows: []}} ->
          {:error, :missing}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  @doc """
  Drops the publication `name` if it exists. Electric makes one beside its slot; a slot
  dropped leaves it behind, listing tables nothing reads any more.
  """
  @spec drop_publication(conn(), String.t()) :: :ok | {:error, term()}
  def drop_publication(conn, name) when is_binary(name) do
    with_connection(conn, fn pid ->
      case Postgrex.query(pid, "drop publication if exists #{quote_ident(name)}", []) do
        {:ok, _} -> :ok
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp quote_ident(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  @doc "The slot Electric uses for a replication stream id."
  @spec name(String.t()) :: String.t()
  def name(replication_stream_id), do: "electric_slot_#{replication_stream_id}"

  defp exists?(pid, name) do
    match?(
      {:ok, %{rows: [_ | _]}},
      Postgrex.query(pid, "select 1 from pg_replication_slots where slot_name = $1", [name])
    )
  end

  defp version(pid) do
    case Postgrex.query(pid, "show server_version_num", []) do
      {:ok, %{rows: [[number]]}} -> String.to_integer(number)
      _ -> 0
    end
  end

  defp with_connection(conn, fun, wait \\ 120_000)
  defp with_connection(pid, fun, _wait) when is_pid(pid), do: fun.(pid)

  # In a process of its own: a connection that cannot be made stops, and a stopped
  # linked connection would take the caller — a node booting — with it.
  defp with_connection(opts, fun, wait) when is_list(opts) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          case Postgrex.start_link(postgrex_opts(opts)) do
            {:ok, conn} ->
              try do
                fun.(conn)
              after
                GenServer.stop(conn)
              end

            {:error, error} ->
              {:error, error}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {:error, reason}
    after
      wait ->
        Process.exit(pid, :kill)
        {:error, :timeout}
    end
  end

  # Electric's connection options, said Postgrex's way.
  @doc false
  # Electric's connection options as Postgrex's: one connection, stopped rather than
  # retried when it cannot be made.
  def postgrex_opts(opts) do
    ssl =
      case Keyword.get(opts, :sslmode) do
        mode when mode in [:require, :verify_ca, :verify_full] -> [ssl: true]
        _ -> []
      end

    opts
    |> Keyword.take([:hostname, :port, :database, :username, :password, :socket_options])
    |> Keyword.merge(ssl)
    |> Keyword.put(:pool_size, 1)
    |> Keyword.put(:backoff_type, :stop)
  end
end
