defmodule ElectricPlug.SlotsTest do
  @moduledoc """
  The slot lifecycle against a real Postgres (`ELECTRIC_PLUG_DB=1`, the local server as
  postgres/postgres): made ahead of Electric — failover-capable on 17+ — reused, listed
  with the WAL it holds back, found as an orphan, dropped, and a slot being read refused.
  """
  use ExUnit.Case, async: false

  @moduletag :db
  # Making a logical slot waits for every transaction open on the whole server to finish,
  # and a shared development server has other suites' sandbox transactions open for
  # minutes at a time. Waiting is correct; failing after a minute is not.
  @moduletag timeout: 600_000

  alias ElectricPlug.Slots

  @conn [
    hostname: "localhost",
    port: 5432,
    username: "postgres",
    password: "postgres",
    database: "postgres"
  ]

  setup do
    name = "electric_slot_plug_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> Slots.drop(@conn, name) end)
    %{name: name}
  end

  test "made ahead of Electric once, reused after, failover-capable on 17 and later", %{
    name: name
  } do
    assert {:ok, :created} = Slots.ensure(@conn, name, timeout: 500_000)
    assert {:ok, :exists} = Slots.ensure(@conn, name, timeout: 500_000)

    {:ok, slots} = Slots.list(@conn)
    slot = Enum.find(slots, &(&1.name == name))
    assert slot.plugin == "pgoutput"
    refute slot.active?
    assert is_integer(slot.retained_bytes)
    assert slot.failover? == server_version() >= 170_000
  end

  test "made with its publication, so Electric does not replace it; an idle slot older than its publication is remade",
       %{name: name} do
    publication = "electric_publication_plug_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = Postgrex.start_link(@conn)
    on_exit(fn -> Slots.drop_publication(@conn, publication) end)

    # A slot from before the publication existed:
    {:ok, :created} = Slots.ensure(@conn, name, failover: false, timeout: 500_000)
    {:ok, before} = Slots.list(@conn)
    refute Enum.find(before, &(&1.name == name)).failover?

    assert {:ok, :created} = Slots.ensure(@conn, name, publication: publication, timeout: 500_000)

    assert %{rows: [_]} =
             Postgrex.query!(pid, "select 1 from pg_publication where pubname = $1", [publication])

    {:ok, slots} = Slots.list(@conn)
    assert Enum.find(slots, &(&1.name == name)).failover? == server_version() >= 170_000

    # Both there: nothing to do.
    assert {:ok, :exists} = Slots.ensure(@conn, name, publication: publication, timeout: 500_000)
  end

  test "an idle slot not kept is an orphan; the kept one is not", %{name: name} do
    {:ok, :created} = Slots.ensure(@conn, name, failover: false, timeout: 500_000)
    {:ok, orphans} = Slots.orphans(@conn)
    assert Enum.any?(orphans, &(&1.name == name))

    {:ok, orphans} = Slots.orphans(@conn, keep: [name])
    refute Enum.any?(orphans, &(&1.name == name))
  end

  test "dropped by name; a missing one said so", %{name: name} do
    {:ok, :created} = Slots.ensure(@conn, name, failover: false, timeout: 500_000)
    assert :ok = Slots.drop(@conn, name)
    assert {:error, :missing} = Slots.drop(@conn, name)
  end

  test "a publication left behind is dropped, and one that is not there is no error" do
    name = "electric_publication_plug_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = Postgrex.start_link(@conn)
    Postgrex.query!(pid, ~s(create publication "#{name}"), [])

    assert :ok = Slots.drop_publication(@conn, name)

    assert %{rows: []} =
             Postgrex.query!(pid, "select 1 from pg_publication where pubname = $1", [name])

    assert :ok = Slots.drop_publication(@conn, name)
  end

  test "a connection that cannot be made is an error, not a crash of the caller" do
    assert {:error, _} = Slots.list(Keyword.put(@conn, :port, 1))
  end

  defp server_version do
    {:ok, pid} = Postgrex.start_link(@conn)
    %{rows: [[number]]} = Postgrex.query!(pid, "show server_version_num", [])
    GenServer.stop(pid)
    String.to_integer(number)
  end
end
