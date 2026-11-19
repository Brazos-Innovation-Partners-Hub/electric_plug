defmodule ElectricPlug.HandleTest do
  @moduledoc """
  A handle the client presents names the log it is sent, so it is served only when the shape
  stored under it is the shape this request derived, whole: against a real Electric and a real
  PostgreSQL (`ELECTRIC_PLUG_DB=1`).

  Electric 1.8.1 takes a presented handle when a 27-bit hash (`:erlang.phash2/1`) of the shape
  stored under it equals the requested shape's (`Electric.ShapeCache.ShapeStatus`'s
  `validate_shape_handle/3`), and that hash covers the where clause, which holds values the
  client chooses (whose rows, which board). A search over such values finds two whose shapes
  hash alike in well under a second, here as an attacker would; every test that presents
  another shape's handle uses such a pair, so that Electric's own check cannot refuse it.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Electric.Shapes.Shape
  alias ElectricPlug.Config
  alias ElectricPlug.Test.Todo

  @moduletag :db
  @moduletag timeout: 300_000

  @conn [hostname: "localhost", port: 5432, username: "postgres", password: "postgres"]
  @database "electric_plug_test"

  setup context do
    Config.reset()

    on_exit(fn ->
      Config.reset()

      for key <- [:env, :connection_opts, :storage_dir, :electric],
          do: Application.delete_env(:electric_plug, key)
    end)

    tmp =
      Path.join(System.tmp_dir!(), "electric-plug-handle-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, admin} = Postgrex.start_link(Keyword.put(@conn, :database, "postgres"))

    case Postgrex.query(admin, "create database #{@database}", []) do
      {:ok, _} -> :ok
      {:error, %Postgrex.Error{postgres: %{code: :duplicate_database}}} -> :ok
    end

    GenServer.stop(admin)

    {:ok, db} = Postgrex.start_link(Keyword.put(@conn, :database, @database))
    run = System.unique_integer([:positive])
    tables = %{table: "handle_rows_#{run}", other: "handle_others_#{run}"}

    for {_, name} <- tables,
        do:
          Postgrex.query!(
            db,
            "create table #{name} (id bigint primary key, owner text, title text)",
            []
          )

    on_exit(fn ->
      {:ok, db} = Postgrex.start_link(Keyword.put(@conn, :database, @database))
      for {_, name} <- tables, do: Postgrex.query(db, "drop table if exists #{name}", [])
    end)

    Application.put_env(:electric_plug, :env, :test)

    Application.put_env(
      :electric_plug,
      :connection_opts,
      Keyword.put(@conn, :database, @database)
    )

    Application.put_env(:electric_plug, :storage_dir, tmp)
    # Electric's own options for the test that needs them (a host that lets clients delete).
    Application.put_env(:electric_plug, :electric, Map.get(context, :electric, []))

    for child <- Config.children(), do: start_supervised!(child)
    :ok = ElectricPlug.Node.await_ready()

    Map.merge(tables, %{db: db, stack: Config.resolved()[:stack_id]})
  end

  test "another person's handle is never served, even one whose shape hashes as his: nothing of hers, 409",
       %{db: db, table: table} do
    {alice, bob} = colliding({table, []}, {table, []})
    insert(db, table, 1, alice, "Alice's first")
    insert(db, table, 2, bob, "Bob's first")

    # Alice reads her rows; her handle and offset travel in the URL of every later request.
    {first, handle, offset} = start(owned(table, alice))
    assert titles(first) == ["Alice's first"]

    # Bob presents them, his live poll waiting while a row naming only Alice is written.
    waiting = Task.async(fn -> poll(owned(table, bob), handle, offset) end)
    insert(db, table, 3, alice, "Alice's second, never Bob's")
    answer = Task.await(waiting, 30_000)

    refute answer.resp_body =~ "Alice", "Bob was sent Alice's rows: #{answer.resp_body}"
    assert answer.status == 409, answer.resp_body
    assert must_refetch?(answer)
    [own] = header(answer, "electric-handle")
    refute own == handle

    # Not live, from her offset, once her row is in her log: the same.
    assert "Alice's second, never Bob's" in follow(owned(table, alice), handle, offset)
    later = serve(owned(table, bob), %{"handle" => handle, "offset" => offset})
    refute later.resp_body =~ "Alice", "Bob was sent Alice's rows: #{later.resp_body}"
    assert later.status == 409, later.resp_body
    assert must_refetch?(later)

    # The handle he is told to start over on is his own shape's: his rows and none of hers.
    {mine, ^own, _offset} = start(owned(table, bob))
    assert titles(mine) == ["Bob's first"]
  end

  test "a handle of a shape of another table is never served, even one that hashes as this request's shape",
       %{db: db, table: table, other: other} do
    {owner, asker} = colliding({other, []}, {table, []})
    insert(db, other, 1, owner, "another table's first")
    {_, handle, offset} = start(owned(other, owner))

    waiting = Task.async(fn -> poll(owned(table, asker), handle, offset) end)
    insert(db, other, 2, owner, "another table's second")
    answer = Task.await(waiting, 30_000)

    refute answer.resp_body =~ "another table",
           "a shape of #{table} was sent #{other}'s rows: #{answer.resp_body}"

    assert answer.status == 409, answer.resp_body
    assert must_refetch?(answer)
    refute header(answer, "electric-handle") == [handle]
  end

  test "a handle of a shape of other columns is never served, even one that hashes as this request's shape",
       %{db: db, table: table} do
    # One shape of every column, the owner's included; the asker's leaves the owner out.
    narrow = [columns: ["id", "title"]]
    {owner, asker} = colliding({table, []}, {table, narrow})
    insert(db, table, 1, owner, "every column's first")
    {_, handle, offset} = start(owned(table, owner))

    waiting = Task.async(fn -> poll(owned(table, asker), handle, offset, narrow) end)
    insert(db, table, 2, owner, "every column's second")
    answer = Task.await(waiting, 30_000)

    refute answer.resp_body =~ "every column",
           "a shape of id and title was sent another shape's rows: #{answer.resp_body}"

    refute answer.resp_body =~ owner
    assert answer.status == 409, answer.resp_body
    assert must_refetch?(answer)
    refute header(answer, "electric-handle") == [handle]
  end

  test "a handle whose shape was deleted is never served: 409, and the shape starts over on a new handle",
       %{db: db, table: table, stack: stack} do
    {alice, bob} = colliding({table, []}, {table, []})
    insert(db, table, 1, alice, "Alice's first")
    {_, handle, offset} = start(owned(table, alice))

    :ok = Electric.Shapes.clean_shape(stack, handle)
    assert Electric.Shapes.fetch_shape_by_handle(stack, handle) == :error

    hers = serve(owned(table, alice), %{"handle" => handle, "offset" => offset})
    assert hers.status == 409, hers.resp_body
    assert must_refetch?(hers)
    [new] = header(hers, "electric-handle")
    refute new == handle

    his = serve(owned(table, bob), %{"handle" => handle, "offset" => offset})
    refute his.resp_body =~ "Alice", "Bob was sent Alice's rows: #{his.resp_body}"
    assert his.status == 409, his.resp_body
    assert must_refetch?(his)
    refute header(his, "electric-handle") in [[handle], [new]]

    # Alice starts over on the handle she was given: her rows.
    {again, ^new, _offset} = start(owned(table, alice))
    assert titles(again) == ["Alice's first"]
  end

  test "a person's own handle resumes her shape: from her offset, then her later rows, live",
       %{db: db, table: table} do
    insert(db, table, 1, "alice", "Alice's first")
    {first, handle, offset} = start(owned(table, "alice"))
    assert titles(first) == ["Alice's first"]

    resumed = serve(owned(table, "alice"), %{"handle" => handle, "offset" => offset})
    assert resumed.status == 200, resumed.resp_body
    assert header(resumed, "electric-handle") == [handle]
    assert titles(resumed) == []

    waiting = Task.async(fn -> poll(owned(table, "alice"), handle, offset) end)
    insert(db, table, 2, "alice", "Alice's second")
    live = Task.await(waiting, 30_000)
    assert live.status == 200, live.resp_body
    assert header(live, "electric-handle") == [handle]
    assert titles(live) == ["Alice's second"]
  end

  test "the serving node's half of a forwarded request refuses another person's handle as serving here does",
       %{db: db, table: table} do
    {alice, bob} = colliding({table, []}, {table, []})
    insert(db, table, 1, alice, "Alice's first")
    {_, handle, offset} = start(owned(table, alice))
    insert(db, table, 2, alice, "Alice's second, never Bob's")
    assert "Alice's second, never Bob's" in follow(owned(table, alice), handle, offset)

    {:ok, his} = ElectricPlug.Shape.params(owned(table, bob))

    {status, headers, body} =
      ElectricPlug.Remote.serve("GET", %{"handle" => handle, "offset" => offset}, his, [])

    refute body =~ "Alice", "Bob was sent Alice's rows: #{body}"
    assert status == 409, body
    refute {"electric-handle", handle} in headers
  end

  @tag electric: [allow_shape_deletion?: true]
  test "where clients may delete shapes, a delete removes only the request's own: another's handle is refused and her shape kept",
       %{db: db, table: table, stack: stack} do
    insert(db, table, 1, "alice", "Alice's first")
    {_, handle, offset} = start(owned(table, "alice"))

    refused = delete(owned(table, "bob"), handle)
    assert refused.status == 409, refused.resp_body
    assert {:ok, _shape} = Electric.Shapes.fetch_shape_by_handle(stack, handle)
    kept = serve(owned(table, "alice"), %{"handle" => handle, "offset" => offset})
    assert kept.status == 200, kept.resp_body
    assert header(kept, "electric-handle") == [handle]

    assert delete(owned(table, "alice"), handle).status == 202
    assert Electric.Shapes.fetch_shape_by_handle(stack, handle) == :error
  end

  # -- requests -------------------------------------------------------------------------------

  # A person's own rows of `table`, as a host's read derives them for that person.
  defp owned(table, owner), do: from(t in {table, Todo}, where: t.owner == ^owner)

  defp serve(query, params, opts \\ []) do
    conn =
      Plug.Test.conn(:get, "/shape?" <> URI.encode_query(params))
      |> Plug.Conn.fetch_query_params()

    ElectricPlug.serve(conn, conn.query_params, query, opts)
  end

  defp delete(query, handle) do
    conn =
      Plug.Test.conn(:delete, "/shape?" <> URI.encode_query(%{"handle" => handle}))
      |> Plug.Conn.fetch_query_params()

    ElectricPlug.serve(conn, conn.query_params, query)
  end

  # The shape read from the start, as a client first asks: the answer, its handle, and the
  # offset it is up to.
  defp start(query, opts \\ []) do
    conn = serve(query, %{"offset" => "-1"}, opts)
    assert conn.status == 200, conn.resp_body
    [handle] = header(conn, "electric-handle")
    [offset] = header(conn, "electric-offset")
    {conn, handle, offset}
  end

  defp poll(query, handle, offset, opts \\ []),
    do: serve(query, %{"handle" => handle, "offset" => offset, "live" => "true"}, opts)

  # The titles the shape's own live polls are sent from `offset` until one arrives: what is
  # then in the shape's log.
  defp follow(query, handle, offset, rounds \\ 5)
  defp follow(_query, _handle, _offset, 0), do: flunk("no change arrived")

  defp follow(query, handle, offset, rounds) do
    conn = poll(query, handle, offset)
    assert conn.status == 200, conn.resp_body

    case titles(conn) do
      [] -> follow(query, handle, hd(header(conn, "electric-offset")), rounds - 1)
      sent -> sent
    end
  end

  defp insert(db, table, id, owner, title) do
    Postgrex.query!(db, "insert into #{table} (id, owner, title) values ($1, $2, $3)", [
      id,
      owner,
      title
    ])
  end

  defp header(conn, name), do: Plug.Conn.get_resp_header(conn, name)

  defp titles(conn) do
    for(%{"value" => value} <- Jason.decode!(conn.resp_body), do: value["title"])
    |> Enum.sort()
  end

  defp must_refetch?(conn) do
    conn.resp_body
    |> Jason.decode!()
    |> Enum.any?(&match?(%{"headers" => %{"control" => "must-refetch"}}, &1))
  end

  # -- two shapes Electric's hash cannot tell apart -------------------------------------------

  # A family of shapes: `table`'s rows owned by one value, served with `opts`.
  defp shape({table, opts}, owner) do
    {:ok, params} = ElectricPlug.Shape.params(owned(table, owner), opts)
    {:ok, %{shape: shape}} = Electric.Shapes.Api.predefined_shape(Config.api(), params)
    shape
  end

  @base "person-0"

  # A value for a shape of `family_a` and one for a shape of `family_b` whose shapes are not
  # the same but hash alike as Electric hashes them to check a presented handle. Searched as an
  # attacker would: a candidate's shape is its family's shape for `@base` with the value put in
  # its where clause, hashed; only the pair found is then made as shapes, and proven so.
  defp colliding(family_a, family_b) do
    hash_a = hasher(family_a)
    hash_b = if family_b == family_a, do: hash_a, else: hasher(family_b)

    {:found, a, b} =
      Enum.reduce_while(1..4_000_000, {%{}, %{}}, fn n, {seen_a, seen_b} ->
        value = "person-#{n}"
        ha = hash_a.(value)
        hb = hash_b.(value)

        cond do
          Map.has_key?(seen_b, ha) -> {:halt, {:found, value, seen_b[ha]}}
          Map.has_key?(seen_a, hb) -> {:halt, {:found, seen_a[hb], value}}
          family_a != family_b and ha == hb -> {:halt, {:found, value, value}}
          true -> {:cont, {Map.put(seen_a, ha, value), Map.put(seen_b, hb, value)}}
        end
      end)

    shape_a = shape(family_a, a)
    shape_b = shape(family_b, b)
    assert Shape.hash(shape_a) == Shape.hash(shape_b)
    refute Shape.comparable(shape_a) == Shape.comparable(shape_b)
    {a, b}
  end

  defp hasher(family) do
    comparable = family |> shape(@base) |> Shape.comparable()
    literal = "'#{@base}'"

    assert occurrences(comparable, literal) == 1,
           "the shape names #{literal} once: #{inspect(comparable)}"

    fn value -> :erlang.phash2(replace(comparable, literal, "'#{value}'")) end
  end

  defp replace(term, from, to) when is_binary(term), do: String.replace(term, from, to)

  defp replace(term, from, to) when is_tuple(term),
    do: term |> Tuple.to_list() |> replace(from, to) |> List.to_tuple()

  defp replace(term, from, to) when is_list(term), do: Enum.map(term, &replace(&1, from, to))
  defp replace(term, _from, _to), do: term

  defp occurrences(term, literal) when is_binary(term),
    do: length(String.split(term, literal)) - 1

  defp occurrences(term, literal) when is_tuple(term),
    do: term |> Tuple.to_list() |> occurrences(literal)

  defp occurrences(term, literal) when is_list(term),
    do: Enum.reduce(term, 0, &(occurrences(&1, literal) + &2))

  defp occurrences(_term, _literal), do: 0
end
