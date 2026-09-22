defmodule ElectricPlug.ConfigTest do
  use ExUnit.Case, async: false

  alias ElectricPlug.Config

  setup do
    Config.reset()

    on_exit(fn ->
      Config.reset()
      Application.delete_env(:electric_plug, :mode)
      Application.delete_env(:electric_plug, :repo)
    end)
  end

  test "a repo's connection becomes Electric's replication connection, SSL and IPv6 said its way" do
    config = [
      hostname: "db",
      port: 6543,
      username: "u",
      password: "p",
      database: "app",
      ssl: true,
      socket_options: [:inet6],
      pool_size: 10
    ]

    connection = Config.from_repo(config)

    assert connection[:hostname] == "db" and connection[:port] == 6543 and
             connection[:database] == "app"

    assert connection[:sslmode] == :require and connection[:ipv6] == true
    refute Keyword.has_key?(connection, :pool_size)
  end

  test "test env gets a stack id, a temporary slot, memory storage and a storage_dir of its own" do
    Application.put_env(:electric_plug, :env, :test)

    Application.put_env(:electric_plug, :connection_opts,
      hostname: "localhost",
      username: "postgres",
      password: "postgres",
      database: "x"
    )

    config = Config.resolved()
    assert config[:stack_id] =~ "electric-stack"
    assert config[:replication_slot_temporary?]
    assert {Electric.ShapeCache.InMemoryStorage, _} = config[:storage]
    assert config[:storage_dir] =~ "electric-plug-test"
    # Resolved once: the children and the API agree on every generated value.
    assert Config.resolved()[:stack_id] == config[:stack_id]
  end

  test "disabled, or nothing to connect to, starts nothing and says why" do
    Application.put_env(:electric_plug, :mode, :disabled)
    assert Config.children() == []
    Config.reset()
    Application.delete_env(:electric_plug, :mode)
    Application.delete_env(:electric_plug, :connection_opts)
    assert {:disabled, reason} = Config.resolved()
    assert reason =~ "repo"
  end
end
