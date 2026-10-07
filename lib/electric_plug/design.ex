# The design is written in vstack_shared's vocabulary, which needs Spark: a host without it has
# no use for the declaration, and the plug itself runs without either.
if Code.ensure_loaded?(VStack.Library) do
  defmodule ElectricPlug.Design do
    @moduledoc """
    `electric_plug`'s design (`VStack.Library`): Electric's shape-log protocol served for an
    Ecto query the host has authorised, with Electric embedded in the application.

    What it promises: nothing it serves is wider than the query the host passes. The table, the
    rows the query's where clause keeps and the query's columns are the whole shape; a client's
    own `table`, `where` and `columns` are ignored, only its place in the log (`offset`,
    `handle`, `live`, `cursor`) is read, and the options a host may add can only narrow the
    columns. In a cluster the shape is decided on the node that received the request, by that
    node's authorisation, and the node serving the stream only reads its log for it. Its meaning
    (`ElectricPlug.Meaning`) asks every host to show, in its declarations, that each query it
    serves comes from a read its policies decide, and fails closed: a host that cannot show it
    breaks the rule rather than passing it.

    An application tells it two things: how this node runs Electric, through its configuration
    (`config :electric_plug`, every key declared here), and, on each request, the authorised
    query (`ElectricPlug.serve/4`). It declares no vocabulary of its own.

    What its code reaches outside the application is the application's own database: Electric,
    once started, reads its logical replication stream and makes the publication and slot it
    reads through; the slots are listed, made and dropped; and a clustered node asks who holds
    Electric's lock. These effects are declared here, each naming the module that has it
    (`by:`), so that Spark, which the declarations are written in, is no dependency of the
    plug at run time.

    It stands with Phoenix and Ecto (`:core`). Its reference is `examples/electric_host`, an
    application that serves an authorised read of its own records through it and reads them
    back with `electric_client`.
    """
    use VStack.Library, extensions: [VStack.Effects]

    library do
      name :electric_plug

      description "Serves Electric's shape log for an Ecto query the host has authorised, with Electric embedded in the application: a client gets exactly the query's rows and columns, live, and cannot widen them."

      version 1
      layer :core
      owner "telic-supply-chains"
      reference "examples/electric_host"

      api ElectricPlug.Revocation,
        stub: true,
        description:
          "Cutting a person off a stream the moment their access ends: their cached shape filters flushed, their waiting long polls ended and their channel joins closed, without waiting for a cache to expire or a socket to reconnect."

      api ElectricPlug.Config.Connection,
        stub: true,
        description:
          "Which connection Electric replicates over, when both a repository and explicit connection options are configured: the explicit options win, and the source is logged."

      api ElectricPlug,
        description:
          "Serves the shape log of an authorised query to a request (`serve/4`): the one call a host's controller makes for each shape request, and nothing else, so a module that calls it is one that serves shapes."

      api ElectricPlug.Shape,
        description:
          "The shape `ElectricPlug.serve/4` serves for a query, as Electric is given it (its table, where clause, columns and replica), for a host that must know what a query will be served as before it serves it."

      api ElectricPlug.Node,
        description:
          "This node's part in serving: whether it serves the stream itself, forwards to the node that does, or neither; what it runs and why (its mode and its Electric's status); the children that run Electric; waiting until it serves; its embedded Electric's configuration, for a test reading the same stack; and reading its configuration again."

      api ElectricPlug.Slots,
        description:
          "Electric's replication slots on the application's database: each listed with the log it holds back, Electric's own made ahead of Electric (failover-capable where the server supports it), the ones nothing reads found, and one dropped."

      api Mix.Tasks.ElectricPlug.Slots,
        description:
          "Lists Electric's replication slots, finds the ones nothing reads and drops one by name, for an operator, using the application's own configuration."

      config :env,
        type: {:one_of, [:dev, :test, :prod]},
        default: :prod,
        description:
          "The environment the application runs in (`config_env()`), which chooses the defaults: in test a stack, a temporary slot and storage of its own for each run, kept in memory; in dev storage under the system's temporary directory; in prod what is configured. Unset, prod is assumed and a warning says so."

      config :mode,
        type: {:one_of, [:embedded, :forward, :disabled]},
        default: :embedded,
        description:
          "What this node runs: Electric, embedded and serving its stream; nothing of its own, every shape request forwarded to the node of its cluster that serves the stream; or nothing at all, so every shape request is refused as unavailable."

      config :repo,
        type: :atom,
        description:
          "The Ecto repository whose connection becomes Electric's replication connection."

      config :connection_opts,
        type: :keyword_list,
        description:
          "Electric's replication connection given directly, instead of a repository: hostname, port, database, username, password and SSL (what `Electric.Config.parse_postgresql_uri!/1` returns)."

      config :start,
        type: :boolean,
        default: true,
        description:
          "Whether this library's application starts Electric itself; false when the host places `ElectricPlug.Node.children/0` in its own supervision tree."

      config :cluster,
        type: :boolean,
        default: false,
        description:
          "Whether this node is one of several sharing the stream: one of them runs Electric at a time, and any of them answers a shape request, forwarding it to that one."

      config :replication_stream_id,
        type: :string,
        description:
          "The name of the stream this node serves, or, forwarding, the one whose serving node it forwards to: Electric's slot, publication and lock are named after it, and every node of a cluster gives the same one. Unset, a test run makes one of its own, and production uses `default` and warns."

      config :storage_dir,
        type: :string,
        description:
          "Where Electric keeps its shapes on this node: in production an absolute path on a persistent volume, and a warning when it is missing or relative; a clustered node keeps them in a directory of their own under it."

      config :slot,
        type:
          {:keyword_list,
           [create: [type: :boolean], failover: [type: {:in, [true, false, :auto]}]]},
        default: [],
        description:
          "Making Electric's replication slot before Electric starts: `create:` (in production unless false) and `failover:` (`:auto`, the default, marks it failover-capable where the server supports it, so a promoted standby has it)."

      config :gate,
        type:
          {:keyword_list,
           [
             poll_ms: [type: :pos_integer],
             race_ms: [type: :pos_integer],
             idle_slot_ms: [type: :pos_integer]
           ]},
        default: [],
        description:
          "When a clustered node starts Electric: how often it asks whether another node holds Electric's lock, how long its own Electric may wait behind another's, and how long a holder's slot may go unread before that holder is taken to be stuck."

      config :log_level,
        type:
          {:one_of, [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug]},
        default: :info,
        description: "The least severe of Electric's own log messages that are kept."

      config :electric,
        type: :keyword_list,
        default: [],
        description:
          "Electric's own options (such as `db_pool_size`), given to the embedded Electric as they are, over the defaults this library chooses for the environment."
    end

    effects do
      reaches :database,
        class: :read,
        by: ElectricPlug.Slots,
        doc:
          "Lists the database's logical replication slots (`list/1`, `orphans/2`): whether something reads each, whether it is failover-capable, and how much of the log it holds back."

      # Making converges: what exists is left as it is, so a repeat finds it and changes nothing.
      reaches :database,
        class: :configure,
        by: ElectricPlug.Slots,
        doc:
          "Makes Electric's publication and replication slot when they are missing (`ensure/3`), the slot failover-capable where the server supports it, dropping an idle slot found without its publication to make it again after it, as Electric itself would replace it; and drops a publication if it exists (`drop_publication/2`)."

      # A drop is never retried: a lost answer is the caller's to hear (`{:error, reason}`), and
      # dropping the same slot again finds it gone (`{:error, :missing}`), the same effect.
      reaches :database do
        class :actuate
        by ElectricPlug.Slots

        doc "Drops a replication slot by name (`drop/2`), refusing one something reads: the log it held back is released, and whatever read it must start again from a new slot."

        promise idempotent_by: [:name], on_unknown: :report
      end

      reaches :database,
        class: :read,
        by: ElectricPlug.Cluster.Gate,
        doc:
          "Asks, with one instant query on a connection that holds nothing, whether another node holds Electric's lock for the stream and whether anything reads its slot."

      reaches :database,
        class: :read,
        by: ElectricPlug.Application,
        doc:
          "Starts Electric (in a cluster, once `ElectricPlug.Cluster.Gate` finds its lock free), which reads the database's logical replication stream through its slot, and each shape's rows when the shape is first read."

      reaches :database,
        class: :configure,
        by: ElectricPlug.Application,
        doc:
          "Electric, once started, makes its publication and slot when they are missing, adds each shape's table to the publication, and holds an advisory lock named after the slot while it serves."
    end
  end
end
