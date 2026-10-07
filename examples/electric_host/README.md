# electric_host

`electric_plug`'s reference: a real host, independent of anything else, that proves the plug
against PostgreSQL with Electric embedded.

A todo list (`ElectricHost.Todos`) whose read lets a person see only their own todos (its
policy) is served at `GET /shapes/todos` (`ElectricHost.TodoShapes`, which declares the read
its query comes from, as `electric_plug`'s rules ask), and read back over HTTP with
`electric_client`, as a browser's client would. Its suite proves a person is served exactly
their own todos, live, whatever table, where clause or columns the client asks for.

    mix test        # makes the database and its table first

It needs a PostgreSQL with logical replication on localhost (postgres/postgres, or `PGHOST`
and `PGPORT`), and serves on port 4418 (`ELECTRIC_HOST_PORT`).
