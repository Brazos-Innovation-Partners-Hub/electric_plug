# electric_plug usage rules

Written by hand: what the design cannot say.

- **Build the query from an authorised read, and pass nothing of the client's into it.** The
  query is the whole contract: a client's `table`, `where` and `columns` are ignored, so a
  host that copies request params into its query hands the client the widening the plug
  refuses. With Ash, build it with `Ash.Query.for_read(resource, action, %{}, actor: actor)`
  and `Ash.data_layer_query/1`, and declare that read in the serving module's effects
  (`calls Resource, :read, class: :read`): the rules this library ships ask for it.
- **The two rules are always checked.** `serves_read` (awaited below) is published by a
  library that serves the reads its own declarations name, EideticUI; where no such library is
  loaded there are none of those facts (`absent: :none`), so a module serving shapes must name
  its read in its effects, or break the rule.
- **`columns:` narrows; nothing widens.** A column the query does not select, a `where:` or a
  `params:` beside the query raises `ArgumentError` before anything is served. Ask
  `ElectricPlug.Shape.params/2` what a query will be served as.
- **Electric's own options go under `electric:`**; the plug's own keys stay beside it. A key of
  Electric's written beside them is not read.
- **Readiness and status live on `ElectricPlug.Node`**, not on `ElectricPlug`, whose one
  function is `serve/4`. A test that changes the configuration while the application runs
  calls `ElectricPlug.Node.reset_configuration/0`; the running Electric is not restarted.
- **A node that runs nothing answers 503**, with `retry-after: 300`: a readiness check should
  ask `ElectricPlug.Node.serving/0` rather than wait for the first refusal.
- **Clustered nodes must be connected** (`dns_cluster`, `libcluster`) and share one
  `replication_stream_id`; `storage_dir` must be absolute and persistent in production.
- **Drop a slot only once nothing will read it again.** `mix electric_plug.slots orphans` names
  the candidates; dropping releases the log the slot held, and whatever read it starts over.

<!-- vstack.usage_rules:begin -->

## electric_plug: what its design declares

_Written by `mix vstack.usage_rules` from `ElectricPlug.Design`, so it never drifts from the code: change the design and run it again. Rules written by hand go outside this part._

Serves Electric's shape log for an Ecto query the host has authorised, with Electric embedded in the application: a client gets exactly the query's rows and columns, live, and cannot widen them.

- Design version 1, at the `:core` layer: it depends only on libraries at its layer or below.
- Its design is owned by the `telic-supply-chains` lane, and `examples/electric_host` proves it against a real host.

### What applications call

- `ElectricPlug`: Serves the shape log of an authorised query to a request (`serve/4`): the one call a host's controller makes for each shape request, and nothing else, so a module that calls it is one that serves shapes.
- `ElectricPlug.Shape`: The shape `ElectricPlug.serve/4` serves for a query, as Electric is given it (its table, where clause, columns and replica), for a host that must know what a query will be served as before it serves it.
- `ElectricPlug.Node`: This node's part in serving: whether it serves the stream itself, forwards to the node that does, or neither; what it runs and why (its mode and its Electric's status); the children that run Electric; waiting until it serves; its embedded Electric's configuration, for a test reading the same stack; and reading its configuration again.
- `ElectricPlug.Slots`: Electric's replication slots on the application's database: each listed with the log it holds back, Electric's own made ahead of Electric (failover-capable where the server supports it), the ones nothing reads found, and one dropped.
- `Mix.Tasks.ElectricPlug.Slots`: Lists Electric's replication slots, finds the ones nothing reads and drops one by name, for an operator, using the application's own configuration.

### Configuration

Given as `config :electric_plug, key: value`; it reads no other key of its own.

- `:env`, of type `{:one_of, [:dev, :test, :prod]}`, `:prod` by default: The environment the application runs in (`config_env()`), which chooses the defaults: in test a stack, a temporary slot and storage of its own for each run, kept in memory; in dev storage under the system's temporary directory; in prod what is configured. Unset, prod is assumed and a warning says so.
- `:mode`, of type `{:one_of, [:embedded, :forward, :disabled]}`, `:embedded` by default: What this node runs: Electric, embedded and serving its stream; nothing of its own, every shape request forwarded to the node of its cluster that serves the stream; or nothing at all, so every shape request is refused as unavailable.
- `:repo`, of type `:atom`: The Ecto repository whose connection becomes Electric's replication connection.
- `:connection_opts`, of type `:keyword_list`: Electric's replication connection given directly, instead of a repository: hostname, port, database, username, password and SSL (what `Electric.Config.parse_postgresql_uri!/1` returns).
- `:start`, of type `:boolean`, `true` by default: Whether this library's application starts Electric itself; false when the host places `ElectricPlug.Node.children/0` in its own supervision tree.
- `:cluster`, of type `:boolean`, `false` by default: Whether this node is one of several sharing the stream: one of them runs Electric at a time, and any of them answers a shape request, forwarding it to that one.
- `:replication_stream_id`, of type `:string`: The name of the stream this node serves, or, forwarding, the one whose serving node it forwards to: Electric's slot, publication and lock are named after it, and every node of a cluster gives the same one. Unset, a test run makes one of its own, and production uses `default` and warns.
- `:storage_dir`, of type `:string`: Where Electric keeps its shapes on this node: in production an absolute path on a persistent volume, and a warning when it is missing or relative; a clustered node keeps them in a directory of their own under it.
- `:slot`, of type `{:keyword_list, [create: [type: :boolean], failover: [type: {:in, [true, false, :auto]}]]}`, `[]` by default: Making Electric's replication slot before Electric starts: `create:` (in production unless false) and `failover:` (`:auto`, the default, marks it failover-capable where the server supports it, so a promoted standby has it).
- `:gate`, of type `{:keyword_list, [poll_ms: [type: :pos_integer], race_ms: [type: :pos_integer], idle_slot_ms: [type: :pos_integer]]}`, `[]` by default: When a clustered node starts Electric: how often it asks whether another node holds Electric's lock, how long its own Electric may wait behind another's, and how long a holder's slot may go unread before that holder is taken to be stuck.
- `:log_level`, of type `{:one_of, [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug]}`, `:info` by default: The least severe of Electric's own log messages that are kept.
- `:electric`, of type `:keyword_list`, `[]` by default: Electric's own options (such as `db_pool_size`), given to the embedded Electric as they are, over the defaults this library chooses for the environment.

### What its declarations mean

Facts its rules define besides, which its own rules and what it generates read:

- `names_a_read(m)` (`ElectricPlug.Meaning`): Module m, which serves shape logs, names at least one Ash read whose query it serves.
- `policed_read(read)` (`ElectricPlug.Meaning`): Read action read is decided by its resource's policies (the resource uses `Ash.Policy.Authorizer`), so the query it builds for an actor keeps only the records that actor may read.
- `served_read(m, read)` (`ElectricPlug.Meaning`): Module m, which serves shape logs, declares the Ash read whose query it serves: an action it calls, classed as a read, in its own effects (`calls Resource, :action, class: :read`).
- `serves_shapes(m)` (`ElectricPlug.Meaning`): Code in module m serves shape logs through ElectricPlug: what it sends a client is exactly the rows and columns of the query m passes, so m is where what a client may see is decided. A module compiled from tests serves no client and is left out.

### Rules it ships

#### To every application and library that uses it: `ElectricPlug.Meaning`

- `:served_shapes_name_their_read`: Every module that serves shape logs through ElectricPlug names, in its effects, the Ash read whose query it serves: a served query nothing accounts for breaks this rule rather than being taken as authorised
- `:served_reads_are_policed`: Every read whose query a module serves through ElectricPlug is decided by its resource's policies: a read no policy decides hands every client every record its query keeps, so it breaks this rule however narrow the query looks

Facts its rules await, which nothing gives yet: until one is given, each rule reading it is reported as not checked, never as holding.

- `serves_read`, from EideticUI's published facts (a library that serves reads its own declarations name): serves_read(m, read): module m serves read, which its library's declarations name.

### Worked examples

Rules shown broken, and why:

- `:served_shapes_name_their_read`, in `ElectricPlug`: A controller that serves its todos through ElectricPlug and declares no read, beside a library that serves the reads its own declarations name (a notes page's): the controller is not one of that library's, so nothing shows that a policy decides its query, which could hold every todo of every owner.
- `:served_reads_are_policed`, in `ElectricPlug`: A library's shape controller that serves a notes read its declarations name, and a todo controller that declares its todo read: neither resource has policies, so nothing decides who may read which note or todo, and every client is served every row the query keeps.

Examples run in a world, each pinning down what it covers:

- `:a_schema_is_served_as_its_table`, covering `ElectricPlug.Shape`: A schema module is served as its table, with every column it maps and no where clause: all of the table's rows, and only those columns.
- `:columns_narrow_the_shape`, covering `ElectricPlug.Shape`: A host that gives fewer columns than its query maps is served exactly those.
- `:columns_never_widen_the_shape`, covering `ElectricPlug.Shape`: A column the query does not map is refused, even one its table has: the columns a host gives only narrow what the query allows.
- `:a_where_beside_the_query_is_refused`, covering `ElectricPlug.Shape`: A where clause given beside the query is refused rather than put in place of the query's: only the query says which rows are served.
- `:a_node_with_no_database_says_why`, covering `ElectricPlug.Node`: A node given neither a repository nor a connection runs no Electric, and says that it is disabled and why.
- `:a_disabled_node_answers_unavailable`, covering `ElectricPlug`: A node configured to run nothing answers a shape request 503 without serving a row, and asks the client to come back much later, since it serves only once configured and restarted.
- `:a_disabled_node_serves_nothing`, covering `ElectricPlug.Node`: A node configured to run nothing neither serves the stream nor forwards to a node that does.

### What it reaches outside the application

- `ElectricPlug.Slots` reaches `:database` (read): Lists the database's logical replication slots (`list/1`, `orphans/2`): whether something reads each, whether it is failover-capable, and how much of the log it holds back.
- `ElectricPlug.Slots` reaches `:database` (configure): Makes Electric's publication and replication slot when they are missing (`ensure/3`), the slot failover-capable where the server supports it, dropping an idle slot found without its publication to make it again after it, as Electric itself would replace it; and drops a publication if it exists (`drop_publication/2`).
- `ElectricPlug.Slots` reaches `:database` (actuate): Drops a replication slot by name (`drop/2`), refusing one something reads: the log it held back is released, and whatever read it must start again from a new slot. A repeat with the same `[:name]` is the same effect; an unknown outcome is handled by `:report`.
- `ElectricPlug.Cluster.Gate` reaches `:database` (read): Asks, with one instant query on a connection that holds nothing, whether another node holds Electric's lock for the stream and whether anything reads its slot.
- `ElectricPlug.Application` reaches `:database` (read): Starts Electric (in a cluster, once `ElectricPlug.Cluster.Gate` finds its lock free), which reads the database's logical replication stream through its slot, and each shape's rows when the shape is first read.
- `ElectricPlug.Application` reaches `:database` (configure): Electric, once started, makes its publication and slot when they are missing, adds each shape's table to the publication, and holds an advisory lock named after the slot while it serves.

<!-- vstack.usage_rules:end -->
