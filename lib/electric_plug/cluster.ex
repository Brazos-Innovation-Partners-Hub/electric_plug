defmodule ElectricPlug.Cluster do
  @moduledoc """
  Several nodes of one application, one replication stream, one Electric serving at a time.

      config :electric_plug,
        replication_stream_id: "my_app",
        storage_dir: "/var/lib/my_app/electric",
        cluster: true

  Every node embeds Electric with the same stream id. Electric's own advisory lock makes
  one of them active — it holds the replication slot and keeps the shapes. The others run
  no Electric until the lock is free (`ElectricPlug.Cluster.Gate`): Electric waits for its
  lock inside a statement, and a statement waiting for hours held up every `CREATE INDEX
  CONCURRENTLY` behind it. With `cluster: true`:

    * **Any node answers a shape request.** A node that is not the active one forwards the
      request over the BEAM cluster to the node that is, and relays its answer. A load
      balancer in front needs no stickiness and no health check on a path: every node is
      as good as every other. The nodes must be connected (`dns_cluster`, `libcluster`).
    * **A node's shapes last one tenure.** Electric's waiting mode assumes the nodes share
      one storage directory; on a disk of its own, a node that became active again would
      restore shapes that missed everything another node read from the slot meanwhile, and
      serve them as current. So a node starts every tenure with empty storage: at boot, and
      whenever it stops being the active node its stack is restarted on a clean directory.
      A handover costs every client one refetch; it never costs a row.

  Storage lives in `<storage_dir>/cluster-tenure`, a directory this module names and
  empties — never `storage_dir` itself, which may hold anything.

  Without `cluster: true` nothing here runs: one node keeps its shapes across restarts,
  which is right when it is the only one reading its slot.
  """

  use GenServer
  require Logger

  @poll_ms 200
  @tenure_dir "cluster-tenure"

  @doc "Whether this application runs Electric as one of several nodes."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:electric_plug, :cluster, false) == true

  @doc "The directory a clustered node's Electric keeps its shapes in, under `storage_dir`."
  @spec tenure_dir(String.t()) :: String.t()
  def tenure_dir(storage_dir), do: Path.join(storage_dir, @tenure_dir)

  @doc """
  Where a shape request is served from: `:local` (this node's stack is active, or this is
  not a cluster), `{:remote, node}` (another node's is), or `:none` (nobody's is yet).
  """
  @spec route() :: :local | {:remote, node()} | :none
  def route do
    cond do
      not enabled?() -> :local
      ElectricPlug.Config.ready?() -> :local
      true -> active_elsewhere()
    end
  end

  @doc "The node serving the stream now: this one, another, or `nil`."
  @spec active_node() :: node() | nil
  def active_node do
    case :global.whereis_name(global_name()) do
      pid when is_pid(pid) -> node(pid)
      :undefined -> nil
    end
  end

  defp active_elsewhere do
    case active_node() do
      nil -> :none
      node when node == node() -> :none
      node -> {:remote, node}
    end
  end

  defp global_name do
    {__MODULE__, Keyword.get(ElectricPlug.Config.electric(), :replication_stream_id, "default")}
  end

  # -- the tenure ------------------------------------------------------------------------

  @doc false
  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config]},
      type: :worker,
      # Stopping at the end of a tenure is how the stack after it gets restarted clean.
      restart: :permanent
    }
  end

  @doc false
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @impl true
  def init(config) do
    dir = Keyword.fetch!(config, :storage_dir)
    # Only a directory this module named: `storage_dir` may be shared with anything.
    true = Path.basename(dir) == @tenure_dir
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    Process.send_after(self(), :poll, @poll_ms)

    {:ok,
     %{
       stack_id: Keyword.fetch!(config, :stack_id),
       name: global_name(),
       active?: false,
       registered?: false
     }}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    active? = status(state.stack_id) == :active

    cond do
      active? and not state.registered? ->
        case :global.register_name(state.name, self(), &:global.random_notify_name/3) do
          :yes ->
            Logger.notice("electric_plug: #{node()} serves the stream")
            {:noreply, %{state | active?: true, registered?: true}}

          # A registration another node has not let go of yet (its node has not been
          # seen to go down): asked again at the next poll.
          :no ->
            {:noreply, %{state | active?: true}}
        end

      state.active? and not active? ->
        if state.registered?, do: :global.unregister_name(state.name)

        Logger.warning(
          "electric_plug: #{node()} is no longer the node serving the stream; its shapes are " <>
            "discarded and its Electric restarted to wait for the lock"
        )

        {:stop, {:shutdown, :tenure_ended}, %{state | registered?: false}}

      true ->
        {:noreply, state}
    end
  end

  # Two registrations met when a split healed: `:global` kept one and told this one.
  def handle_info({:global_name_conflict, _name}, state),
    do: {:noreply, %{state | registered?: false}}

  defp status(stack_id) do
    Electric.StatusMonitor.service_status(stack_id)
  rescue
    _ -> :starting
  catch
    :exit, _ -> :starting
  end
end
