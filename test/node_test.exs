defmodule ElectricPlug.NodeTest do
  @moduledoc """
  What a node runs, read from `config :electric_plug` by its keys, and what it answers when it
  runs nothing.
  """
  use ExUnit.Case, async: false

  alias ElectricPlug.{Config, Node}

  @keys [:mode, :repo, :connection_opts, :env, :electric, :replication_stream_id, :storage_dir]

  setup do
    Node.reset_configuration()

    on_exit(fn ->
      Enum.each(@keys, &Application.delete_env(:electric_plug, &1))
      Node.reset_configuration()
    end)
  end

  test "a node with nothing to connect to is disabled, and says why" do
    assert {:disabled, reason} = Node.mode()
    assert reason =~ "repo"
    assert Node.status() == :disabled
    assert Node.serving() == :unavailable
    assert Node.children() == []
    assert Node.electric() == []
  end

  test "a node configured to run nothing is disabled with no reason" do
    Application.put_env(:electric_plug, :mode, :disabled)
    assert Node.mode() == {:disabled, nil}
  end

  test "a forwarding node runs nothing of its own" do
    Application.put_env(:electric_plug, :mode, :forward)
    Application.put_env(:electric_plug, :replication_stream_id, "todos")
    assert Node.mode() == :forward
    assert Node.status() == :forwarding
    assert Config.stream_id() == "todos"
  end

  test "the configuration is read once, and again after a reset" do
    assert {:disabled, _} = Node.mode()
    Application.put_env(:electric_plug, :mode, :forward)
    assert {:disabled, _} = Node.mode()
    Node.reset_configuration()
    assert Node.mode() == :forward
  end

  test "Electric's own options come from `electric:`, beside this library's own keys" do
    Application.put_env(:electric_plug, :env, :prod)
    Application.put_env(:electric_plug, :storage_dir, "/var/lib/todos/electric")
    Application.put_env(:electric_plug, :replication_stream_id, "todos")

    Application.put_env(:electric_plug, :connection_opts,
      hostname: "localhost",
      username: "postgres",
      password: "postgres",
      database: "todos"
    )

    Application.put_env(:electric_plug, :electric, db_pool_size: 3, replication_stream_id: "x")

    config = Config.resolved()
    assert config[:db_pool_size] == 3
    assert config[:storage_dir] == "/var/lib/todos/electric"
    # This library's own key wins over the same one among Electric's options.
    assert config[:replication_stream_id] == "todos"
    assert config[:replication_connection_opts][:database] == "todos"
    assert Node.mode() == :embedded
    assert Node.electric() == config
  end

  test "a disabled node answers a shape request 503, and asks the client to come back later" do
    Application.put_env(:electric_plug, :mode, :disabled)
    conn = Plug.Test.conn(:get, "/shape?offset=-1")
    conn = ElectricPlug.serve(conn, %{"offset" => "-1"}, ElectricPlug.Test.Todo)
    assert conn.status == 503
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["300"]
    assert conn.resp_body =~ "disabled"
  end
end
