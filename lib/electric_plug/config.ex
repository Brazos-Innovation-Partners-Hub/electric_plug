defmodule ElectricPlug.Config do
  @moduledoc false
  # Turns `config :electric_plug` into Electric's configuration, once. The children and
  # the API must agree on the stack id, the storage and the slot, and in test those are
  # generated per run — so the first resolution is kept and every later call reads it.

  require Logger

  @ours [:env, :mode, :repo, :connection_opts, :start]

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
        [{Electric.StackSupervisor, Electric.Application.configuration(config)}]
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

    opts
    |> Keyword.put(:stack_id, stack_id)
    |> Keyword.put_new(:replication_stream_id, "electric_plug#{run}" |> String.replace("-", "_"))
    |> Keyword.put_new(:replication_slot_temporary?, true)
    |> Keyword.put_new(
      :storage,
      {Electric.ShapeCache.InMemoryStorage,
       table_base_name: :"electric-storage#{stack_id}", stack_id: stack_id}
    )
    |> Keyword.put_new(:persistent_kv, {Electric.PersistentKV.Memory, :new!, []})
    # Electric keeps shape status on disk under storage_dir whatever the log storage
    # is; with logs in memory it must not outlive the run.
    |> Keyword.put_new(:storage_dir, Path.join(System.tmp_dir!(), "electric-plug-test#{run}"))
  end

  defp env_defaults(opts, :dev) do
    opts
    |> Keyword.put_new(:send_cache_headers?, false)
    |> Keyword.put_new(:storage_dir, Path.join(System.tmp_dir!(), "electric-plug-dev"))
  end

  defp env_defaults(opts, _prod), do: opts
end
