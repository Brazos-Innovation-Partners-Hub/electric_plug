defmodule ElectricPlug.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Logger.put_application_level(:electric, level())

    children =
      if Application.get_env(:electric_plug, :start, true),
        do: ElectricPlug.Config.children(),
        else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: ElectricPlug.Supervisor)
  end

  # Electric is verbose; its notices are ours to raise when we need them.
  defp level do
    case System.get_env("ELECTRIC_LOG_LEVEL") do
      nil ->
        :info

      configured ->
        if configured in Enum.map(Logger.levels(), &to_string/1),
          do: String.to_existing_atom(configured),
          else: :info
    end
  end
end
