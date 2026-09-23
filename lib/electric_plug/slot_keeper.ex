defmodule ElectricPlug.SlotKeeper do
  @moduledoc false
  # Makes Electric's slot before Electric does, so it can be made failover-capable (see
  # `ElectricPlug.Slots.ensure/3`), then steps aside. A slot that cannot be made now is
  # said and left to Electric, which makes an ordinary one: a node must boot.

  use GenServer
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil) do
    case ElectricPlug.Config.slot_plan() do
      nil ->
        :ignore

      {connection, name, opts} ->
        case ElectricPlug.Slots.ensure(connection, name, opts) do
          {:ok, outcome} ->
            Logger.info("electric_plug: replication slot #{name}: #{outcome}")

          {:error, error} ->
            Logger.warning(
              "electric_plug: could not make replication slot #{name} ahead of Electric " <>
                "(#{inspect(error)}); Electric will make an ordinary one"
            )
        end

        :ignore
    end
  end
end
