defmodule ElectricPlug.Cluster.Gate do
  @moduledoc """
  When a clustered node runs Electric, so that a node that is not serving never waits
  inside Postgres.

  Electric makes one node active with an advisory lock, taken by a blocking statement on
  its replication connection: `SELECT pg_advisory_lock(hashtext(slot))`. A node started
  beside an active one sits in that statement for as long as the other serves — hours —
  and a statement in progress holds a snapshot. `CREATE INDEX CONCURRENTLY` waits, in
  "waiting for old snapshots", for every such statement older than it: a migration never
  finished while another node waited, and the deploy that would have restarted that node
  never got there (Forge, 2026-09-25).

  So a node does not start Electric to wait. The gate asks, with one instant query on a
  connection of its own that holds nothing, whether another node holds the lock. While
  one does, this node runs no Electric at all; it still answers every shape request,
  forwarded to the node that serves (`ElectricPlug.Cluster`). When the lock is free the
  tenure starts. Two nodes that saw it free together race for it: the one whose Electric
  is then waiting behind the other's lock for `race_ms` stops its tenure and asks again,
  so a wait inside Postgres lasts seconds, never a tenure.

  A holder whose slot nobody has read for `idle_slot_ms` is stuck, not serving — a node
  whose replication stopped with its lock connection still open. Then the tenure starts
  anyway, and waits, so that Electric's own lock breaker, which runs only while waiting,
  can end that connection.
  """

  use GenServer
  require Logger

  # How often the lock is asked about (a handover waits for the next ask, then for
  # Electric to start); how long this node's Electric may wait behind another's lock; how
  # long a holder's slot may go unread before the tenure starts to break it. Overridden
  # with `config :electric_plug, gate: [...]`.
  @defaults [poll_ms: 500, race_ms: 5_000, idle_slot_ms: 30_000]

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "What the gate is doing now: `:idle` (no Electric here) or `:tenure`."
  @spec state() :: :idle | :tenure
  def state, do: GenServer.call(__MODULE__, :state)

  @typedoc "What the lock looked like to one probe."
  @type seen :: %{held?: boolean(), slot_active?: boolean()} | :unknown

  @doc """
  What to do next, given what the gate holds (`:idle` or `:tenure`), this node's
  Electric's connection status (`:waiting_on_lock` or anything else), what the probe
  saw, and how long the lock has been held behind a waiting Electric (`waited_ms`) or
  held with its slot unread (`idle_ms`). Pure, for the tests.
  """
  @spec decide(:idle | :tenure, atom(), seen(), keyword()) :: :start | :stop | :stay
  def decide(:idle, _conn, :unknown, _times), do: :stay
  def decide(:idle, _conn, %{held?: false}, _times), do: :start

  def decide(:idle, _conn, %{held?: true, slot_active?: false}, times),
    do:
      if(Keyword.fetch!(times, :idle_ms) >= Keyword.fetch!(times, :idle_slot_ms),
        do: :start,
        else: :stay
      )

  def decide(:idle, _conn, %{held?: true}, _times), do: :stay

  # Waiting behind another node's lock: allowed for `race_ms`, and never while the
  # holder's slot is unread — that wait is how Electric's lock breaker gets to run.
  def decide(:tenure, :waiting_on_lock, %{held?: true, slot_active?: true}, times),
    do:
      if(Keyword.fetch!(times, :waited_ms) >= Keyword.fetch!(times, :race_ms),
        do: :stop,
        else: :stay
      )

  def decide(:tenure, _conn, _seen, _times), do: :stay

  # -- the loop ----------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # The probe's connection is linked; one that drops is a message here, not a crash.
    Process.flag(:trap_exit, true)
    opts = Keyword.merge(@defaults, opts)

    state = %{
      stack_id: Keyword.fetch!(opts, :stack_id),
      slot: Keyword.fetch!(opts, :slot),
      connection: Keyword.fetch!(opts, :connection),
      tenure: Keyword.fetch!(opts, :tenure),
      supervisor: Keyword.get(opts, :supervisor, ElectricPlug.Cluster.Tenures),
      poll_ms: Keyword.fetch!(opts, :poll_ms),
      race_ms: Keyword.fetch!(opts, :race_ms),
      idle_slot_ms: Keyword.fetch!(opts, :idle_slot_ms),
      probe: Keyword.get(opts, :probe, &probe/2),
      status: Keyword.get(opts, :status, &electric_conn/1),
      running: nil,
      held_since: nil,
      idle_since: nil,
      conn: nil
    }

    {:ok, adopt(state), {:continue, :poll}}
  end

  # A gate restarted beside a tenure it started carries on with that tenure, rather than
  # starting a second Electric or leaving one it does not watch.
  defp adopt(state) do
    case DynamicSupervisor.which_children(state.supervisor) do
      [{_, pid, _, _} | _] when is_pid(pid) ->
        Process.monitor(pid)
        %{state | running: pid}

      _ ->
        state
    end
  catch
    :exit, _ -> state
  end

  @impl true
  def handle_continue(:poll, state), do: {:noreply, poll(state)}

  @impl true
  def handle_info(:poll, state), do: {:noreply, poll(state)}

  # The tenure stopped by itself — its supervisor gave up restarting it. Asked again.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{running: pid} = state),
    do: {:noreply, %{state | running: nil, held_since: nil}}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:state, _from, state),
    do: {:reply, if(state.running, do: :tenure, else: :idle), state}

  @impl true
  def terminate(_reason, state) do
    if state.conn, do: GenServer.stop(state.conn, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp poll(state) do
    Process.send_after(self(), :poll, state.poll_ms)
    {seen, state} = look(state)
    now = System.monotonic_time(:millisecond)

    held_behind? =
      state.running != nil and match?(%{held?: true}, seen) and conn(state) == :waiting_on_lock

    unread? = match?(%{held?: true, slot_active?: false}, seen)

    state = %{
      state
      | held_since: if(held_behind?, do: state.held_since || now, else: nil),
        idle_since: if(unread?, do: state.idle_since || now, else: nil)
    }

    times = [
      waited_ms: if(state.held_since, do: now - state.held_since, else: 0),
      idle_ms: if(state.idle_since, do: now - state.idle_since, else: 0),
      race_ms: state.race_ms,
      idle_slot_ms: state.idle_slot_ms
    ]

    case decide(if(state.running, do: :tenure, else: :idle), conn(state), seen, times) do
      :start -> start_tenure(state)
      :stop -> stop_tenure(state)
      :stay -> state
    end
  end

  defp start_tenure(state) do
    case DynamicSupervisor.start_child(state.supervisor, state.tenure) do
      {:ok, pid} ->
        Process.monitor(pid)
        Logger.info("electric_plug: the lock is free; #{node()} starts Electric")
        %{state | running: pid, held_since: nil}

      {:error, reason} ->
        Logger.warning("electric_plug: could not start Electric's tenure: #{inspect(reason)}")
        state
    end
  end

  defp stop_tenure(state) do
    Logger.info(
      "electric_plug: another node holds the lock; #{node()} stops waiting for it and asks again"
    )

    DynamicSupervisor.terminate_child(state.supervisor, state.running)
    %{state | running: nil, held_since: nil}
  end

  defp conn(%{running: nil}), do: nil
  defp conn(state), do: state.status.(state.stack_id)

  # This node's Electric's connection status: `:waiting_on_lock` until it holds the lock.
  defp electric_conn(stack_id) do
    Electric.StatusMonitor.status(stack_id).conn
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # One instant query on a connection that holds nothing: a session, never a transaction
  # left open. A probe that cannot be made is `:unknown`, and nothing changes on it.
  defp look(state) do
    case ensure_conn(state) do
      {:ok, state} ->
        case state.probe.(state.conn, state.slot) do
          {:ok, seen} -> {seen, state}
          {:error, _} -> {:unknown, drop_conn(state)}
        end

      {:error, state} ->
        {:unknown, state}
    end
  end

  defp ensure_conn(%{conn: pid} = state) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, state}, else: ensure_conn(%{state | conn: nil})
  end

  defp ensure_conn(%{connection: connection} = state) when is_list(connection) do
    case Postgrex.start_link(ElectricPlug.Slots.postgrex_opts(connection)) do
      {:ok, pid} ->
        {:ok, %{state | conn: pid}}

      {:error, _} ->
        {:error, state}
    end
  end

  # A connection given ready-made (a test's), used as it is.
  defp ensure_conn(%{connection: pid} = state) when is_pid(pid), do: {:ok, %{state | conn: pid}}

  defp drop_conn(%{conn: pid, connection: connection} = state)
       when is_pid(pid) and is_list(connection) do
    GenServer.stop(pid, :normal, 1_000)
    %{state | conn: nil}
  catch
    :exit, _ -> %{state | conn: nil}
  end

  defp drop_conn(state), do: state

  @doc """
  Whether a session holds Electric's lock for `slot`, and whether anything reads the slot,
  as Electric's own lock breaker asks.
  """
  @spec probe(pid(), String.t()) :: {:ok, seen()} | {:error, term()}
  def probe(conn, slot) do
    sql = """
    select
      exists (
        select 1 from pg_locks
        where locktype = 'advisory' and granted and objsubid = 1
          and database = (select oid from pg_database where datname = current_database())
          and ((classid::bigint << 32) | objid::bigint) = hashtext($1)
      ),
      coalesce((select active from pg_replication_slots where slot_name = $1), false)
    """

    case Postgrex.query(conn, sql, [slot], timeout: 5_000) do
      {:ok, %{rows: [[held, active]]}} -> {:ok, %{held?: held, slot_active?: active}}
      {:error, error} -> {:error, error}
    end
  catch
    :exit, reason -> {:error, reason}
  end
end
