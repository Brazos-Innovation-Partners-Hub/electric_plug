defmodule ElectricPlug.Node do
  @moduledoc """
  This node's part in serving shapes: what it runs (`mode/0`), whether it serves the stream
  itself, forwards to the node that does, or neither (`serving/0`), its Electric's status
  (`status/0`), the children that run Electric (`children/0`), and waiting until it serves
  (`ready?/0`, `await_ready/1`). For readiness checks, a host's own supervision tree and tests.

  What it runs comes from `config :electric_plug`, read once and kept: `reset_configuration/0`
  forgets it, for a test or a drill that changes the configuration while the application runs.
  """

  alias ElectricPlug.Config

  @doc """
  What this node runs: `:embedded` (Electric, serving its stream), `:forward` (nothing of its
  own; every shape request goes to the node of its cluster that serves the stream), or
  `{:disabled, reason}` (nothing; every shape request is answered 503). The reason is `nil`
  when the configuration says `mode: :disabled`, and says what is missing otherwise.
  """
  @spec mode() :: :embedded | :forward | {:disabled, String.t() | nil}
  def mode do
    case Config.resolved() do
      {:disabled, reason} -> {:disabled, reason}
      {:forward, _stream} -> :forward
      _config -> :embedded
    end
  end

  @doc """
  Whether this node can answer a shape request, and how: `:active` (its own Electric serves
  the stream), `{:forwarding, node}` (it sends requests to the node that does), or
  `:unavailable`. For readiness checks.
  """
  @spec serving() :: :active | {:forwarding, node()} | :unavailable
  def serving do
    case ElectricPlug.Cluster.route() do
      :local -> if ready?(), do: :active, else: :unavailable
      {:remote, node} -> {:forwarding, node}
      :none -> :unavailable
    end
  end

  @doc """
  This node's Electric: Electric's own status when it runs one (`:active`, `:waiting` behind
  another node's lock, `:starting`, `:sleeping`), `:forwarding` when it runs none and forwards,
  `:disabled` when it runs none at all.
  """
  @spec status() :: :active | :waiting | :starting | :sleeping | :forwarding | :disabled
  def status do
    case mode() do
      {:disabled, _reason} -> :disabled
      :forward -> :forwarding
      :embedded -> Config.service_status()
    end
  end

  @doc "Whether this node's Electric is up and serving. For readiness checks."
  @spec ready?() :: boolean()
  def ready?, do: Config.ready?()

  @doc """
  Blocks until this node's Electric serves, or answers `{:error, reason}` after `timeout`
  milliseconds (`:disabled` or a reason, `:forwarding`, `:timeout`). For a test helper.
  """
  @spec await_ready(pos_integer()) :: :ok | {:error, term()}
  def await_ready(timeout \\ 60_000), do: Config.await_ready(timeout)

  @doc """
  The children that run Electric, from the configuration: `[]` when this node runs none. This
  library's application starts them itself; a host that places them in its own supervision
  tree sets `start: false`.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children, do: Config.children()

  @doc """
  Forgets the configuration read from `config :electric_plug`, so that the next call reads it
  again. The running Electric is not restarted: for a test or a drill that changes what this
  node runs while the application runs.
  """
  @spec reset_configuration() :: :ok
  def reset_configuration, do: Config.reset()
end
