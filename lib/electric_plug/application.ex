defmodule ElectricPlug.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Electric is verbose; its notices are ours to raise when we need them (`log_level:`).
    Logger.put_application_level(
      :electric,
      Application.get_env(:electric_plug, :log_level, :info)
    )

    children =
      if Application.get_env(:electric_plug, :start, true),
        do: ElectricPlug.Config.children(),
        else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: ElectricPlug.Supervisor)
  end
end
