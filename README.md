# electric_plug

Serves [Electric](https://electric-sql.com)'s shape-log protocol for an authorised Ecto
query, with Electric embedded in the application. The thin part of `phoenix_sync`, kept
current with Electric.

```elixir
config :electric_plug, env: config_env(), repo: MyApp.Repo

def show(conn, params) do
  ElectricPlug.serve(conn, params, from(t in Todo, where: t.owner_id == ^user.id))
end
```

The query is the contract: a client gets exactly its rows and cannot widen the shape.
Per-environment defaults (test: memory, temporary slot, fresh storage per run) need no
configuration. See `ElectricPlug`'s docs.

Why this exists: upstream `phoenix_sync` stopped shipping in October 2025 and caps
Electric at 1.1.10; Electric's own Elixir client stopped tracking its server at 1.6.
This library depends on Electric directly and on our copy of the client, and its
consumer's suite (EideticUI: 670+ tests against Postgres and Electric, a browser
harness) is its acceptance test. Portions derive from phoenix_sync (Apache-2.0).
