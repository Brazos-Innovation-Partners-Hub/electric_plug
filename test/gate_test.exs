defmodule ElectricPlug.GateTest do
  @moduledoc """
  A clustered node that is not serving runs no Electric while another node holds the
  lock, so it never sits inside Postgres in `pg_advisory_lock` — a statement that holds a
  snapshot, and that `CREATE INDEX CONCURRENTLY` waits behind for as long as it runs
  (Forge's deploy, 2026-09-25). Against a real Postgres with `ELECTRIC_PLUG_DB=1`.
  """
  use ExUnit.Case, async: false

  alias ElectricPlug.Cluster.Gate

  @conn [hostname: "localhost", port: 5432, username: "postgres", password: "postgres"]
  @times [waited_ms: 0, idle_ms: 0, race_ms: 5_000, idle_slot_ms: 30_000]

  describe "what the gate does" do
    test "with no Electric here: starts when the lock is free, waits while a serving node holds it" do
      assert Gate.decide(:idle, nil, %{held?: false, slot_active?: false}, @times) == :start
      assert Gate.decide(:idle, nil, %{held?: true, slot_active?: true}, @times) == :stay
      assert Gate.decide(:idle, nil, :unknown, @times) == :stay
    end

    test "starts behind a holder whose slot nobody reads, once it has been so long enough" do
      unread = %{held?: true, slot_active?: false}
      assert Gate.decide(:idle, nil, unread, @times) == :stay
      assert Gate.decide(:idle, nil, unread, Keyword.put(@times, :idle_ms, 30_000)) == :start
    end

    test "with Electric here: stops one waiting behind a serving node's lock, after race_ms" do
      serving = %{held?: true, slot_active?: true}
      assert Gate.decide(:tenure, :waiting_on_lock, serving, @times) == :stay

      assert Gate.decide(
               :tenure,
               :waiting_on_lock,
               serving,
               Keyword.put(@times, :waited_ms, 5_000)
             ) == :stop

      # Its own lock, taken and still starting; serving; or waiting to break a stuck one.
      assert Gate.decide(:tenure, :starting, serving, Keyword.put(@times, :waited_ms, 60_000)) ==
               :stay

      assert Gate.decide(:tenure, :up, serving, Keyword.put(@times, :waited_ms, 60_000)) == :stay

      assert Gate.decide(
               :tenure,
               :waiting_on_lock,
               %{held?: true, slot_active?: false},
               Keyword.put(@times, :waited_ms, 60_000)
             ) ==
               :stay
    end
  end

  describe "against Postgres" do
    @describetag :db

    setup do
      database = "electric_plug_test"
      {:ok, admin} = Postgrex.start_link(Keyword.put(@conn, :database, "postgres"))

      case Postgrex.query(admin, "create database #{database}", []) do
        {:ok, _} -> :ok
        {:error, %Postgrex.Error{postgres: %{code: :duplicate_database}}} -> :ok
      end

      GenServer.stop(admin)
      connection = Keyword.put(@conn, :database, database)
      {:ok, holder} = Postgrex.start_link(connection)
      {:ok, probe} = Postgrex.start_link(connection)
      slot = "electric_slot_gate_#{System.unique_integer([:positive])}"
      %{connection: connection, holder: holder, probe: probe, slot: slot}
    end

    test "the probe sees a session holding the lock, whichever sign its hash has", %{
      holder: holder,
      probe: probe
    } do
      # hashtext is a signed 32-bit hash; Electric's key is it as a bigint.
      signs =
        for name <- Enum.map(1..40, &"electric_slot_sign_#{&1}"), into: %{} do
          {:ok, %{rows: [[hash]]}} = Postgrex.query(probe, "select hashtext($1)", [name])
          {hash < 0, name}
        end

      for {_negative?, name} <- signs do
        assert {:ok, %{held?: false}} = Gate.probe(probe, name)
        Postgrex.query!(holder, "select pg_advisory_lock(hashtext($1))", [name])
        assert {:ok, %{held?: true, slot_active?: false}} = Gate.probe(probe, name)
        Postgrex.query!(holder, "select pg_advisory_unlock(hashtext($1))", [name])
      end

      assert map_size(signs) == 2
    end

    test "a node starts its tenure when the lock is free, never while another holds it, and stops one caught waiting",
         %{connection: connection, holder: holder, slot: slot} do
      Postgrex.query!(holder, "select pg_advisory_lock(hashtext($1))", [slot])
      test = self()
      waiting = :atomics.new(1, [])

      tenure = %{
        id: :tenure,
        restart: :temporary,
        start: {Agent, :start_link, [fn -> send(test, :tenure_started) end]}
      }

      start_supervised!(
        {DynamicSupervisor, name: ElectricPlug.Cluster.Tenures, strategy: :one_for_one}
      )

      start_supervised!({
        Gate,
        # A stand-in for Electric's status: waiting on the lock while the test says so.
        # The node holding the lock serves: its slot is read. (No slot is made here.)
        stack_id: "gate-test",
        slot: slot,
        connection: connection,
        tenure: tenure,
        poll_ms: 50,
        race_ms: 300,
        status: fn _ -> if :atomics.get(waiting, 1) == 1, do: :waiting_on_lock, else: :up end,
        probe: fn conn, slot ->
          with {:ok, seen} <- Gate.probe(conn, slot),
               do: {:ok, %{seen | slot_active?: seen.held?}}
        end
      })

      # Held by another node: no Electric here, however long.
      refute_receive :tenure_started, 500
      assert Gate.state() == :idle

      # Let go: this node's tenure starts.
      Postgrex.query!(holder, "select pg_advisory_unlock(hashtext($1))", [slot])
      assert_receive :tenure_started, 2_000
      assert Gate.state() == :tenure

      # Another node took it first, and this node's Electric is waiting behind it: stopped.
      :atomics.put(waiting, 1, 1)
      Postgrex.query!(holder, "select pg_advisory_lock(hashtext($1))", [slot])
      Process.sleep(700)
      assert Gate.state() == :idle
      refute_receive :tenure_started, 300
    end

    test "CREATE INDEX CONCURRENTLY is not held up by a node that is not serving",
         %{connection: connection, holder: holder, probe: probe, slot: slot} do
      table = "gate_cic_#{System.unique_integer([:positive])}"
      Postgrex.query!(probe, "create table #{table} (id int)", [])

      on_exit(fn ->
        with_conn(connection, &Postgrex.query(&1, "drop table if exists #{table}", []))
      end)

      # The serving node: a session holding the lock, as Electric's does.
      Postgrex.query!(holder, "select pg_advisory_lock(hashtext($1))", [slot])

      # What a waiting node used to be: a session inside pg_advisory_lock. The index waits
      # for it ("waiting for old snapshots") — here, until its own timeout.
      waiter =
        Task.async(fn ->
          with_conn(
            connection,
            &Postgrex.query(&1, "select pg_advisory_lock(hashtext($1))", [slot], timeout: 15_000)
          )
        end)

      await_waiting(probe, slot)

      assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
               with_conn(connection, fn conn ->
                 Postgrex.query!(conn, "set statement_timeout = 2000", [])

                 Postgrex.query(
                   conn,
                   "create index concurrently #{table}_waited on #{table} (id)",
                   [],
                   timeout: 10_000
                 )
               end)

      Task.shutdown(waiter, :brutal_kill)
      with_conn(connection, &Postgrex.query(&1, "drop index if exists #{table}_waited", []))

      with_conn(
        connection,
        &Postgrex.query(
          &1,
          "select pg_terminate_backend(pid) from pg_stat_activity where datname = current_database() and state = 'active' and wait_event = 'advisory' and pid <> pg_backend_pid()",
          []
        )
      )

      # With the gate, a node that is not serving has no such session: the index is made.
      start_supervised!(
        {DynamicSupervisor, name: ElectricPlug.Cluster.Tenures, strategy: :one_for_one}
      )

      tenure = %{
        id: :tenure,
        restart: :temporary,
        start: {Agent, :start_link, [fn -> :tenure end]}
      }

      start_supervised!(
        {Gate,
         stack_id: "gate-test", slot: slot, connection: connection, tenure: tenure, poll_ms: 50}
      )

      Process.sleep(300)
      assert Gate.state() == :idle

      assert {:ok, _} =
               with_conn(connection, fn conn ->
                 Postgrex.query!(conn, "set statement_timeout = 10000", [])

                 Postgrex.query(
                   conn,
                   "create index concurrently #{table}_made on #{table} (id)",
                   [],
                   timeout: 15_000
                 )
               end)
    end
  end

  defp with_conn(connection, fun) do
    {:ok, conn} = Postgrex.start_link(connection)

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

  # Until the waiting session is inside pg_advisory_lock.
  defp await_waiting(probe, slot, tries \\ 50) do
    {:ok, %{rows: [[n]]}} =
      Postgrex.query(
        probe,
        "select count(*) from pg_stat_activity where datname = current_database() and wait_event_type = 'Lock' and wait_event = 'advisory' and query like 'select pg_advisory_lock%'",
        []
      )

    cond do
      n > 0 -> :ok
      tries == 0 -> flunk("the waiting session never waited (#{slot})")
      true -> Process.sleep(100) && await_waiting(probe, slot, tries - 1)
    end
  end
end
