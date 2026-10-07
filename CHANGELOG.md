# Changelog

## Designed, not built (2026-10-07, lane libraries)

- `ElectricPlug.Revocation`: a revoked person's cached shape filters flushed, waiting long polls ended
  and channel joins closed at once, called by the host's authority changes. Refuses as not built.
- `ElectricPlug.Config.Connection`: with a repository and explicit `connection_opts` both set, the
  explicit replication address wins and the source is named at boot. Refuses as not built.

## 0.3.0 — unreleased

Brought to the library standard: the design is declared (`ElectricPlug.Design`), what serving
means is stated as facts with two rules every host follows (`ElectricPlug.Meaning`), and the
worked examples run in the suite. Breaking for hosts:

- **`ElectricPlug` holds `serve/4` alone,** so a module that calls it is one that serves
  shapes. `serving/0`, `ready?/0`, `await_ready/1` and `children/0` move to `ElectricPlug.Node`,
  beside `mode/0` (`:embedded`, `:forward` or `{:disabled, reason}`), `status/0` (this node's
  Electric: `:active`, `:waiting`, `:starting`, `:sleeping`, `:forwarding` or `:disabled`) and
  `reset_configuration/0` and `electric/0` (the embedded Electric's configuration as resolved,
  for a test that reads the same stack with `Electric.Client.embedded/1`, which called
  `ElectricPlug.Config.electric/0`). `api/0` is gone: it let a host drive Electric around the authorised
  query, and nothing called it. `ElectricPlug.Config` is internal; call `ElectricPlug.Node`.
- **Electric's own options move under `electric:`**:
  `config :electric_plug, electric: [db_pool_size: 4]`. Every key is read by its name and
  declared in the design; options of Electric's written beside this library's own are no
  longer read. `replication_stream_id` and `storage_dir`, which this library reads too, stay
  beside them (or among them; beside wins).
- **`log_level:`** sets the level of Electric's own log messages (default `:info`), in place of
  the `ELECTRIC_LOG_LEVEL` environment variable: set it from the variable in `runtime.exs`.
- The configuration as resolved is kept apart from the application's configuration (it was
  under `:__resolved__`); a test that changes the configuration calls
  `ElectricPlug.Node.reset_configuration/0`.
- **Rules every host follows** (`ElectricPlug.Meaning`), failing closed: a module that serves
  shapes names, in its effects, the Ash read its query comes from
  (`calls Resource, :read, class: :read`), and that read is decided by its resource's policies
  (`Ash.Policy.Authorizer`).

Fixed:

- **A shape can no longer be wider than its query.** `columns:` replaced the query's columns,
  so it could name a column the query does not select; and `where:` and `params:` options
  replaced the query's where clause. Now `columns:` only narrows (a column the query does not
  select is refused), `where:`, `params:` and any other option are refused, and `serve/4`
  raises `ArgumentError` before anything is served. `ElectricPlug.Shape.params/2` says what a
  query is served as.
- A disabled node answers a shape request 503, with `retry-after: 300`, instead of raising.

## 0.2.5 — 2026-09-30

- `mode: :forward`: a node that runs no Electric and answers every shape request by sending
  it to the node of its cluster serving `replication_stream_id`, and 503 with `retry-after`
  while none is. It needs no connection, slot or storage, and counts as clustered without
  `cluster: true`. For nodes that serve an application's requests but must not read its
  stream: Forge's web tier on VCCP, whose machines have no direct path to the primary. A
  disabled node had answered 500, and a clustered one that ran no Electric looked for the
  node serving `"default"` rather than its stream, and never forwarded.

## 0.2.4 — 2026-09-25

- A long poll can be ended while it waits. `ElectricPlug.serve/4` takes `interrupt:`, a
  message the request's process may be sent; a live request given one is served in a
  process of its own, as cluster mode serves one, and answered at once, 403 "access to
  this shape has ended", when the message comes. How a host ends an ejected actor's
  access rather than letting their long poll stream for up to twenty more seconds
  (EideticUI's `eject/2`). A request that is not live, or not given one, is served as
  before. A forwarded request is watched the same way on the node that forwards it.

## 0.2.3 — 2026-09-25

- A clustered node that is not serving no longer waits inside Postgres. Electric takes its
  lock with a blocking `SELECT pg_advisory_lock(hashtext(slot))` on its replication
  connection, so every other node sat in that statement for as long as the active one
  served, and a statement in progress holds a snapshot: `CREATE INDEX CONCURRENTLY` waits
  for every one older than it ("waiting for old snapshots"), and a Forge deploy's
  migration never finished until the two waiting sessions were terminated by hand. A
  gate (`ElectricPlug.Cluster.Gate`) now starts a node's Electric only when the lock is
  free, asking with one instant query on a connection that holds nothing; a node whose
  Electric then waits behind another's lock (two raced) stops it after five seconds and
  asks again. A holder whose slot nobody reads for thirty seconds is stuck, and the node
  waits for it so that Electric's lock breaker can end it. A handover now also waits for
  the next ask (half a second) and for Electric to start. `await_ready/1` waits for a
  tenure that has not started yet rather than failing. Proven against Postgres (an index
  is made while another node holds the lock, and is held up by a session waiting in the
  old way) and by EideticUI's cluster drill.

## 0.2.2 — 2026-09-25

- A policy comparing an atom attribute to a literal becomes a shape. Ash writes every
  comparison with its type explicit, `type(^value, type)`, and the Ecto adapter rendered
  the bound value as it was: an Ash atom or `Ecto.Enum` member (`:space`) raised
  "unsupported expression", so any page whose policy named a kind, a state or a status
  answered 500 (Forge's rooms and knowledge). `electric_client` 7590315 dumps such a value
  through its type — a string-stored atom by its name — and casts it as it is stored:
  `("kind"::varchar = 'space'::varchar)`.

## 0.2.1 — 2026-09-23

- A column added by a migration while Electric runs is served. Electric's inspector kept
  describing the table as it was, and learnt otherwise only from a change to a table a
  shape already read — so a shape asking for the new column was refused, no shape was made,
  and every request failed until someone deleted the persisted inspector state by hand
  (reported by the patchnotes-web lane). Refused for a column or a where it does not know,
  the relation is now forgotten and the shape asked for once more.

## 0.2.0 — 2026-09-23

Several nodes, and Electric's slot looked after. Proved by EideticUI's Electric cluster
drill (`drill/electric-cluster` there): three nodes, a primary and a standby, rolling
restarts, the serving node killed twice, a failover — every client exactly right after
each, where the same nodes without cluster mode left clients hundreds of rows wrong.

- **`cluster: true`** (`ElectricPlug.Cluster`): nodes sharing a stream id serve it from
  one Electric — any node answers a shape request, forwarding over the BEAM cluster to
  the node whose Electric is active; a node's shapes last one tenure (kept under
  `<storage_dir>/cluster-tenure`, emptied at boot and when the node stops serving), so a
  node serving again never restores shapes that missed another node's reads; a long poll
  waiting when a tenure ends is answered `503` at once instead of after its twenty seconds.
- `serving/0`: `:active`, `{:forwarding, node}` or `:unavailable`, for readiness.
- In production the slot is made ahead of Electric, with its publication, failover-capable
  on PostgreSQL 17+, so a promoted standby has it (`ElectricPlug.Slots`, `slot:` config).
  Electric replaces a slot older than its publication, so making only the slot was undone
  at first boot.
- `mix electric_plug.slots [list | orphans | drop NAME]`.
- Production warns at boot about a missing or relative `storage_dir` and an unnamed stream.
- Test runs drop their publication and remove their `storage_dir` at exit; both were left
  behind for every run.

## 0.1.0 — 2026-09-22

First release. `ElectricPlug.serve/4`, `children/0`, `api/0`, `ready?/0`; embedded
Electric 1.8 started from `config :electric_plug`.
