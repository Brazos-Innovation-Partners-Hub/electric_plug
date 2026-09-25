# Changelog

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
