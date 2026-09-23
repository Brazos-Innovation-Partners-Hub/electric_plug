defmodule ElectricPlug.Config do
  @moduledoc false
  # Turns `config :electric_plug` into Electric's configuration, once. The children and
  # the API must agree on the stack id, the storage and the slot, and in test those are
  # generated per run — so the first resolution is kept and every later call reads it.

  require Logger

  @ours [:env, :mode, :repo, :connection_opts, :start, :slot, :cluster]

  @doc "The Electric configuration, resolved once per VM."
  def resolved do
    case Application.fetch_env(:electric_plug, :__resolved__) do
      {:ok, config} ->
        config

      :error ->
        config = resolve(Application.get_all_env(:electric_plug))
        Application.put_env(:electric_plug, :__resolved__, config)
        config
    end
  end

  @doc false
  def reset, do: Application.delete_env(:electric_plug, :__resolved__)

  def mode do
    case resolved() do
      {:disabled, _reason} -> :disabled
      _ -> :embedded
    end
  end

  def children do
    case resolved() do
      {:disabled, reason} ->
        if reason, do: Logger.info("electric_plug: not starting Electric: #{reason}")
        []

      config ->
        stack = {Electric.StackSupervisor, Electric.Application.configuration(config)}

        if ElectricPlug.Cluster.enabled?() do
          # The tenure first, the stack after it: when a tenure ends the tenure stops, and
          # `rest_for_one` takes the stack down with it and starts both again — the tenure
          # emptying the storage before the stack opens it.
          [
            ElectricPlug.SlotKeeper,
            %{
              id: ElectricPlug.Cluster.Stack,
              type: :supervisor,
              start:
                {Supervisor, :start_link,
                 [
                   [{ElectricPlug.Cluster, config}, stack],
                   [strategy: :rest_for_one, max_restarts: 10, max_seconds: 60]
                 ]}
            }
          ]
        else
          [ElectricPlug.SlotKeeper, stack]
        end
    end
  end

  @doc "The resolved Electric configuration, or `[]` when disabled."
  def electric do
    case resolved() do
      {:disabled, _} -> []
      config -> config
    end
  end

  def api do
    case resolved() do
      {:disabled, reason} ->
        raise "electric_plug is disabled#{if reason, do: ": " <> reason, else: ""}; nothing can be served."

      config ->
        config |> Electric.Application.api_plug_opts() |> Keyword.fetch!(:api)
    end
  end

  def ready? do
    case resolved() do
      {:disabled, _} ->
        false

      config ->
        Electric.StatusMonitor.service_status(Keyword.fetch!(config, :stack_id)) == :active
    end
  rescue
    _ -> false
  end

  @doc "Blocks until the stack is active, or `{:error, reason}` after `timeout` ms (default 60 s)."
  def await_ready(timeout \\ 60_000) do
    case resolved() do
      {:disabled, reason} ->
        {:error, reason || :disabled}

      config ->
        Electric.StatusMonitor.wait_until_active(Keyword.fetch!(config, :stack_id),
          timeout: timeout
        )
    end
  end

  # -- resolution ---------------------------------------------------------------------

  defp resolve(opts) do
    env = Keyword.get(opts, :env) || warn_env()

    case Keyword.get(opts, :mode, :embedded) do
      :disabled ->
        {:disabled, nil}

      :embedded ->
        case connection(opts) do
          {:ok, connection_opts} ->
            opts
            |> Keyword.drop(@ours)
            |> Keyword.put(:replication_connection_opts, connection_opts)
            |> env_defaults(env)
            |> cluster_defaults(Keyword.get(opts, :cluster, false))
            |> Keyword.put_new(:stack_id, "electric-embedded")
            |> Keyword.put_new(:stack_ready_timeout, 5_000)

          {:error, reason} ->
            {:disabled, reason}
        end

      other ->
        raise ArgumentError,
              "electric_plug: mode must be :embedded or :disabled, got #{inspect(other)}"
    end
  end

  # A clustered node keeps its shapes for one tenure, in a directory of their own.
  defp cluster_defaults(opts, true) do
    storage_dir = Keyword.get(opts, :storage_dir, "./persistent")
    Keyword.put(opts, :storage_dir, ElectricPlug.Cluster.tenure_dir(storage_dir))
  end

  defp cluster_defaults(opts, _), do: opts

  defp warn_env do
    Logger.warning(
      "electric_plug: no `env` configured; assuming :prod. Set `config :electric_plug, env: config_env()`."
    )

    :prod
  end

  defp connection(opts) do
    case {Keyword.get(opts, :repo), Keyword.get(opts, :connection_opts)} do
      {nil, [_ | _] = connection_opts} ->
        {:ok, connection_opts}

      {nil, nil} ->
        {:error, "no `repo` or `connection_opts` configured"}

      {repo, _} when is_atom(repo) ->
        if Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0) do
          {:ok, from_repo(repo.config())}
        else
          {:error, "#{inspect(repo)} is not an Ecto.Repo"}
        end
    end
  end

  # An Ecto repo's connection configuration as Electric's: the same keys, SSL and IPv6
  # said the way Electric says them.
  @doc false
  def from_repo(repo_config) do
    expected = Electric.connection_opts_schema() |> Keyword.keys()

    ssl =
      case Keyword.get(repo_config, :ssl) do
        off when off in [nil, false] -> [sslmode: :disable]
        true -> [sslmode: :require]
        _ -> []
      end

    tcp = if :inet6 in Keyword.get(repo_config, :socket_options, []), do: [ipv6: true], else: []

    repo_config
    |> Keyword.take(expected)
    |> Keyword.merge(ssl)
    |> Keyword.merge(tcp)
    |> Keyword.put_new(:port, 5432)
  end

  defp env_defaults(opts, :test) do
    run = System.monotonic_time()
    stack_id = Keyword.get(opts, :stack_id, "electric-stack#{run}")

    stream =
      Keyword.get_lazy(opts, :replication_stream_id, fn ->
        "electric_plug#{run}" |> String.replace("-", "_")
      end)

    # The slot is temporary and goes with the run; the publication Electric makes beside it
    # does not, and a hundred and fifty of them had gathered on one test database, each
    # listing the tables its run synced (2026-09-23).
    if Keyword.get(opts, :replication_slot_temporary?, true) do
      connection = Keyword.fetch!(opts, :replication_connection_opts)

      System.at_exit(fn _ ->
        ElectricPlug.Slots.drop_publication(connection, "electric_publication_#{stream}")
      end)
    end

    opts
    |> Keyword.put(:stack_id, stack_id)
    |> Keyword.put(:replication_stream_id, stream)
    |> Keyword.put_new(:replication_slot_temporary?, true)
    |> Keyword.put_new(
      :storage,
      {Electric.ShapeCache.InMemoryStorage,
       table_base_name: :"electric-storage#{stack_id}", stack_id: stack_id}
    )
    |> Keyword.put_new(:persistent_kv, {Electric.PersistentKV.Memory, :new!, []})
    # Electric keeps shape status on disk under storage_dir whatever the log storage
    # is; with logs in memory it must not outlive the run.
    |> Keyword.put_new_lazy(:storage_dir, fn ->
      dir = Path.join(System.tmp_dir!(), "electric-plug-test#{run}")
      # One per run, and runs are many: two hundred of them had gathered in /tmp.
      System.at_exit(fn _ -> File.rm_rf(dir) end)
      dir
    end)
  end

  defp env_defaults(opts, :dev) do
    opts
    |> Keyword.put_new(:send_cache_headers?, false)
    |> Keyword.put_new(:storage_dir, Path.join(System.tmp_dir!(), "electric-plug-dev"))
  end

  # Production is Electric's own defaults, which are right — persistent file storage and a
  # persistent slot — but for two that are not safe to leave to them: the storage
  # directory is `./persistent`, relative to wherever a release happens to start (often
  # read-only, or replaced on every deploy), and the stream id is "default", which on a
  # database with two applications, or a cluster whose nodes each chose one, is a slot
  # collision or an orphan waiting to happen. Both are said, once, at boot.
  defp env_defaults(opts, _prod) do
    storage_dir = Keyword.get(opts, :storage_dir)

    cond do
      is_nil(storage_dir) ->
        Logger.warning(
          "electric_plug: no `storage_dir`; Electric will keep shapes under ./persistent, relative " <>
            "to the release's working directory. Set it to a persistent volume."
        )

      Path.type(storage_dir) != :absolute ->
        Logger.warning(
          "electric_plug: `storage_dir` #{inspect(storage_dir)} is relative; set an absolute path on a persistent volume."
        )

      true ->
        :ok
    end

    if is_nil(Keyword.get(opts, :replication_stream_id)) do
      Logger.warning(
        "electric_plug: no `replication_stream_id`; the slot is `electric_slot_default`. Name the " <>
          "stream after the application (and give every node of a cluster the same one)."
      )
    end

    opts
  end

  @doc """
  What the slot keeper should do before Electric starts: `{connection_opts, slot_name,
  ensure_opts}` (`failover:`, `publication:`), or `nil` when it should do nothing. Production makes the slot itself
  (failover-capable where the server can) unless `slot: [create: false]`; test and dev do
  not, and a temporary slot is never made ahead.
  """
  def slot_plan do
    case resolved() do
      {:disabled, _} ->
        nil

      config ->
        slot = Application.get_env(:electric_plug, :slot, [])
        env = Application.get_env(:electric_plug, :env, :prod)
        create = Keyword.get(slot, :create, env == :prod)

        if create and not Keyword.get(config, :replication_slot_temporary?, false) do
          stream = Keyword.get(config, :replication_stream_id, "default")
          name = Keyword.get(config, :slot_name, ElectricPlug.Slots.name(stream))

          publication = Keyword.get(config, :publication_name, "electric_publication_#{stream}")

          {Keyword.fetch!(config, :replication_connection_opts), name,
           [failover: Keyword.get(slot, :failover, :auto), publication: publication]}
        end
    end
  end
end
