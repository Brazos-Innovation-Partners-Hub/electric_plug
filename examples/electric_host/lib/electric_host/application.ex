defmodule ElectricHost.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    port = Application.fetch_env!(:electric_host, :port)

    children = [
      ElectricHost.Repo,
      {Bandit, plug: ElectricHost.Router, ip: :loopback, port: port, startup_log: false}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ElectricHost.Supervisor)
  end
end
