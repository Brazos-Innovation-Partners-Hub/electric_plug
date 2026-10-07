defmodule ElectricPlug.Config.Connection do
  @moduledoc """
  The replication connection. Logical replication cannot pass a connection pooler, so a host
  that sets `repo` (for its queries) and `connection_opts` (for replication) means the second for
  Electric.

    * `choose/1`: given the configuration, the connection Electric uses: `connection_opts` when it is
      set, because it is the explicit replication address, else the repository's. A configuration
      that sets `connection_opts` to something unusable is refused at boot, naming both;
    * `source/1`: which of the two was used, for the line logged at boot: `:connection_opts` or
      `:repo`.

  Nothing is dropped without saying so: a host that set both is told which won.

  Designed and not yet built: each function refuses as not built until it is
  (`ElectricPlug.Examples`, a worked example each).
  """
  use VStack.Design.Stub.Module,
    functions: [choose: 1, source: 1],
    description:
      "Which connection Electric replicates over, when both a repository and explicit connection options are configured: the explicit options win, and the source is logged."
end
