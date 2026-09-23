# Changelog

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
