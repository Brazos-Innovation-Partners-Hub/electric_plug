defmodule ElectricPlug.ClusterTest do
  @moduledoc """
  Cluster mode on one node: where its storage goes, what a tenure empties and what it
  refuses to, the answer when no node serves, and — against a real Postgres
  (`ELECTRIC_PLUG_DB=1`) — the serving node's half of a forwarded request answering
  exactly what serving it locally answers, and the serving node registered for the others
  to find. Several nodes, handovers and failover are the drill's (`drill/electric-cluster`
  in EideticUI), with numbers.
  """
  use ExUnit.Case, async: false

  alias ElectricPlug.{Cluster, Config}

  @conn [hostname: "localhost", port: 5432, username: "postgres", password: "postgres"]

  setup do
    Config.reset()

    on_exit(fn ->
      Config.reset()

      for key <- [
            :env,
            :mode,
            :connection_opts,
            :cluster,
            :storage_dir,
            :repo,
            :replication_stream_id
          ],
          do: Application.delete_env(:electric_plug, key)
    end)

    tmp =
      Path.join(System.tmp_dir!(), "electric-plug-cluster-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  test "a clustered node keeps its shapes in a directory of their own, under a stack that restarts with it",
       %{tmp: tmp} do
    Application.put_env(:electric_plug, :env, :prod)
    Application.put_env(:electric_plug, :cluster, true)
    Application.put_env(:electric_plug, :storage_dir, tmp)
    Application.put_env(:electric_plug, :replication_stream_id, "cluster_test")
    Application.put_env(:electric_plug, :connection_opts, Keyword.put(@conn, :database, "x"))
    on_exit(fn -> Application.delete_env(:electric_plug, :replication_stream_id) end)

    assert Config.resolved()[:storage_dir] == Path.join(tmp, "cluster-tenure")

    assert [ElectricPlug.SlotKeeper, %{id: ElectricPlug.Cluster.Stack, type: :supervisor}] =
             Config.children()
  end

  test "a tenure starts on an empty directory, and never empties one it did not name", %{tmp: tmp} do
    dir = Cluster.tenure_dir(tmp)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a-shape-from-before"), "stale")

    pid = start_supervised!({Cluster, [stack_id: "no-such-stack", storage_dir: dir]})
    assert File.ls!(dir) == []
    stop_supervised!(Cluster)
    refute Process.alive?(pid)

    other = Path.join(tmp, "somebody-elses")
    File.mkdir_p!(other)
    File.write!(Path.join(other, "keep"), "mine")
    Process.flag(:trap_exit, true)
    assert {:error, _} = Cluster.start_link(stack_id: "no-such-stack", storage_dir: other)
    assert File.read!(Path.join(other, "keep")) == "mine"
  end

  test "with no node serving, a clustered node answers 503 and when to ask again" do
    Application.put_env(:electric_plug, :env, :prod)
    Application.put_env(:electric_plug, :cluster, true)
    Application.put_env(:electric_plug, :connection_opts, Keyword.put(@conn, :database, "x"))

    conn =
      Plug.Test.conn(:get, "/shape?offset=-1")
      |> ElectricPlug.Serve.call(%{"offset" => "-1"}, table: "t")

    assert conn.status == 503
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["1"]
    assert ElectricPlug.Node.serving() == :unavailable
  end

  test "a local shape whose lookup cannot reach Postgres returns 503 with a retryable message" do
    Application.put_env(:electric_plug, :env, :prod)
    Application.put_env(:electric_plug, :connection_opts, @conn)
    Config.reset()

    message = "Cannot connect to the database to verify the shape. Please try again later."

    conn =
      ElectricPlug.Serve.local(
        Plug.Test.conn(:get, "/shape"),
        %{"offset" => "-1"},
        [table: "t"],
        fn _api, _shape -> {:error, {:connection_not_available, [message]}} end
      )

    assert conn.status == 503
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["1"]
    assert Jason.decode!(conn.resp_body) == %{"message" => message}
    refute conn.resp_body =~ "connection_not_available"

    invalid =
      ElectricPlug.Serve.local(
        Plug.Test.conn(:get, "/shape"),
        %{"offset" => "-1"},
        [table: "t"],
        fn _api, _shape -> {:error, {:table, ["does not exist"]}} end
      )

    assert invalid.status == 400

    assert Jason.decode!(invalid.resp_body) == %{
             "message" => inspect({:table, ["does not exist"]})
           }
  end

  describe "a forwarding node" do
    # Forge's web tier serves /app for every user from machines that must not read the stream:
    # a disabled node answered 500, and even clustered it looked for the node serving
    # "default", found none and answered 503, never forwarding (Forge issue 01a0f3b5).
    setup do
      Application.put_env(:electric_plug, :mode, :forward)
      Application.put_env(:electric_plug, :replication_stream_id, "forward_test")
      :ok
    end

    test "starts nothing, needs no connection, and counts as clustered" do
      assert Config.mode() == :forward
      assert Config.children() == []
      assert Config.electric() == []
      refute Config.ready?()
      assert Config.await_ready(10) == {:error, :forwarding}
      assert Cluster.enabled?()
    end

    test "looks for the node serving its stream, by the stream's id" do
      assert Cluster.active_node() == nil
      :yes = :global.register_name({Cluster, "forward_test"}, self())
      on_exit(fn -> :global.unregister_name({Cluster, "forward_test"}) end)

      assert Cluster.active_node() == node()
      # Never itself: a forwarding node serves nothing of its own.
      assert Cluster.route() == :none
    end

    test "with no node serving its stream, answers 503 and when to ask again" do
      conn =
        Plug.Test.conn(:get, "/shape?offset=-1")
        |> ElectricPlug.Serve.call(%{"offset" => "-1"}, table: "t")

      assert conn.status == 503
      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["1"]
      assert ElectricPlug.Node.serving() == :unavailable
    end
  end

  describe "against Postgres" do
    @describetag :db

    setup %{tmp: tmp} do
      database = "electric_plug_test"
      admin = Keyword.put(@conn, :database, "postgres")
      {:ok, pid} = Postgrex.start_link(admin)

      case Postgrex.query(pid, "create database #{database}", []) do
        {:ok, _} -> :ok
        {:error, %Postgrex.Error{postgres: %{code: :duplicate_database}}} -> :ok
      end

      GenServer.stop(pid)

      {:ok, db} = Postgrex.start_link(Keyword.put(@conn, :database, database))
      table = "cluster_rows_#{System.unique_integer([:positive])}"
      Postgrex.query!(db, "create table #{table} (id int primary key, name text)", [])
      Postgrex.query!(db, "insert into #{table} values (1, 'first'), (2, 'second')", [])

      on_exit(fn ->
        {:ok, db} = Postgrex.start_link(Keyword.put(@conn, :database, database))
        Postgrex.query(db, "drop table if exists #{table}", [])
      end)

      Application.put_env(:electric_plug, :env, :test)

      Application.put_env(
        :electric_plug,
        :connection_opts,
        Keyword.put(@conn, :database, database)
      )

      Application.put_env(:electric_plug, :storage_dir, tmp)

      for child <- Config.children(), do: start_supervised!(child)
      :ok = ElectricPlug.Node.await_ready()
      %{table: table}
    end

    test "the serving node's half of a forwarded request answers what serving it here does", %{
      table: table
    } do
      params = %{"offset" => "-1"}
      shape = [table: table]

      direct = ElectricPlug.Serve.local(Plug.Test.conn(:get, "/shape"), params, shape)
      {status, headers, body} = ElectricPlug.Remote.serve("GET", params, shape, [])

      assert status == direct.status and status == 200
      assert body == direct.resp_body
      rows = body |> Jason.decode!() |> Enum.flat_map(&List.wrap(&1["value"]))
      assert Enum.sort(Enum.map(rows, & &1["name"])) == ["first", "second"]

      handle = fn headers -> for {"electric-handle", value} <- headers, do: value end
      assert handle.(headers) == handle.(direct.resp_headers)
      assert [_] = handle.(headers)
    end

    test "a column added while Electric runs is served, not refused until its cache is deleted",
         %{
           table: table
         } do
      params = %{"offset" => "-1"}

      conn = fn columns ->
        ElectricPlug.Serve.local(Plug.Test.conn(:get, "/shape"), params,
          table: table,
          columns: columns
        )
      end

      # Electric reads the table as it is now.
      assert conn.(["id", "name"]).status == 200

      {:ok, db} = Postgrex.start_link(Keyword.put(@conn, :database, "electric_plug_test"))
      Postgrex.query!(db, "alter table #{table} add column colour text", [])

      answer = conn.(["id", "name", "colour"])
      assert answer.status == 200, answer.resp_body
      assert answer.resp_body =~ "colour"
    end

    test "a long poll waiting when the node's tenure ends is answered at once, not after the poll",
         %{tmp: tmp, table: table} do
      start_supervised!(
        {Cluster, [stack_id: Config.resolved()[:stack_id], storage_dir: Cluster.tenure_dir(tmp)]}
      )

      shape = [table: table]
      {200, headers, _} = ElectricPlug.Remote.serve("GET", %{"offset" => "-1"}, shape, [])
      header = fn name -> for {^name, value} <- headers, do: value end
      [handle] = header.("electric-handle")
      [offset] = header.("electric-offset")

      live = %{"offset" => offset, "handle" => handle, "live" => "true"}
      poll = Task.async(fn -> ElectricPlug.Remote.serve("GET", live, shape, []) end)
      # Waiting on the shape, with nothing to say for the next twenty seconds.
      assert Task.yield(poll, 500) == nil

      from = System.monotonic_time(:millisecond)
      stop_supervised!(Cluster)
      assert {503, headers, body} = Task.await(poll, 5_000)
      assert System.monotonic_time(:millisecond) - from < 1_000
      assert {"retry-after", "1"} in headers
      assert body =~ "stopped serving"
    end

    test "the node whose stack is active registers itself as the one serving", %{tmp: tmp} do
      start_supervised!(
        {Cluster, [stack_id: Config.resolved()[:stack_id], storage_dir: Cluster.tenure_dir(tmp)]}
      )

      Application.put_env(:electric_plug, :cluster, true)

      assert wait_until(fn -> Cluster.active_node() == node() end)
      assert Cluster.route() == :local
      assert ElectricPlug.Node.serving() == :active
    end
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && wait_until(fun, tries - 1)
    end
  end
end
