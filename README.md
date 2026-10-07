# electric_plug

Serves [Electric](https://electric-sql.com)'s shape-log protocol for an authorised Ecto
query, with Electric embedded in the application. The thin part of `phoenix_sync`, kept
current with Electric.

```elixir
config :electric_plug,
  env: config_env(),
  repo: MyApp.Repo,
  replication_stream_id: "my_app",
  # Electric's own options, given to Electric as they are:
  electric: [db_pool_size: 4]

def show(conn, params) do
  ElectricPlug.serve(conn, params, from(t in Todo, where: t.owner_id == ^user.id))
end
```

The query is the contract: a client gets exactly its rows and columns and cannot widen the
shape, and the options a host adds can only narrow it (`ElectricPlug.Shape`). Per-environment
defaults (test: memory, temporary slot, fresh storage per run) need no configuration.
`ElectricPlug.Node` says what a node runs and whether it serves. See `ElectricPlug`'s docs.

## Its design

The library's design is declared in `ElectricPlug.Design` (the library standard): the API
applications call, every configuration key it reads, and what its code reaches outside the
application (the application's own database). What serving means is in `ElectricPlug.Meaning`,
with two rules every host follows, failing closed: a module that serves shapes names, in its
effects, the Ash read its query comes from, and that read is decided by its resource's
policies. A host that serves a query it does not account for breaks the rule:

```elixir
defmodule MyAppWeb.TodoShapes do
  use MyAppWeb, :controller
  use VStack.Effects

  effects do
    calls MyApp.Todos.Todo, :read, class: :read, doc: "The read whose query is served"
  end

  def show(conn, params) do
    query = MyApp.Todos.Todo |> Ash.Query.for_read(:read, %{}, actor: conn.assigns.actor)
    {:ok, query} = Ash.Query.data_layer_query(query)
    ElectricPlug.serve(conn, params, query)
  end
end
```

Its worked examples (`ElectricPlug.Examples`) run in its suite; its reference,
`examples/electric_host`, serves an authorised read through it to `electric_client`, against a
real PostgreSQL. `usage-rules.md` is written from the design (`mix vstack.usage_rules`).

## Testing

`mix test` runs without a database. The tests marked `:db` need a PostgreSQL with logical
replication on localhost (postgres/postgres): `ELECTRIC_PLUG_DB=1 mix test`. `mix precommit`
runs formatting, compiling with warnings as errors, the suite, the library standard against
`design/facts.json`, the usage rules check and the reference application's suite.

## Why this exists

Upstream `phoenix_sync` stopped shipping in October 2025 and caps Electric at 1.1.10;
Electric's own Elixir client stopped tracking its server at 1.6. This library depends on
Electric directly and on our copy of the client, and its consumer's suite (EideticUI: 670+
tests against Postgres and Electric, a browser harness) is its acceptance test. Portions
derive from phoenix_sync (Apache-2.0).
