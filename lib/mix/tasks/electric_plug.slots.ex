defmodule Mix.Tasks.ElectricPlug.Slots do
  @shortdoc "Lists, finds orphaned, or drops Electric's replication slots"

  @moduledoc """
  Electric's replication slots on the application's database, for an operator.

      mix electric_plug.slots                     # every logical slot, what it holds back
      mix electric_plug.slots orphans             # Electric's slots no running stream reads
      mix electric_plug.slots drop electric_slot_old_node

  A slot nobody reads keeps WAL until it is dropped; `orphans` names the ones that look
  like that (inactive, `electric_slot_` prefix, not this application's own stream's slot),
  with the WAL each holds back. Nothing is dropped unless named. Uses the application's
  `config :electric_plug` connection, so run it where the application's config is.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:postgrex)

    connection =
      case ElectricPlug.Config.resolved() do
        {:disabled, reason} -> Mix.raise("electric_plug is disabled: #{reason}")
        config -> Keyword.fetch!(config, :replication_connection_opts)
      end

    own =
      ElectricPlug.Config.slot_plan()
      |> then(fn plan -> if plan, do: [elem(plan, 1)], else: [] end)

    case argv do
      [] ->
        {:ok, slots} = ElectricPlug.Slots.list(connection)
        Enum.each(slots, &print/1)

      ["orphans"] ->
        {:ok, slots} = ElectricPlug.Slots.orphans(connection, keep: own)
        if slots == [], do: Mix.shell().info("no orphaned Electric slots")
        Enum.each(slots, &print/1)

      ["drop", name] ->
        case ElectricPlug.Slots.drop(connection, name) do
          :ok -> Mix.shell().info("dropped #{name}")
          {:error, :active} -> Mix.raise("#{name} is being read; stop what reads it first")
          {:error, :missing} -> Mix.raise("no slot #{name}")
          {:error, error} -> Mix.raise(inspect(error))
        end

      _ ->
        Mix.raise("usage: mix electric_plug.slots [orphans | drop NAME]")
    end
  end

  defp print(slot) do
    Mix.shell().info(
      "#{slot.name}\t#{if slot.active?, do: "reading", else: "idle"}\t" <>
        "#{if slot.failover?, do: "failover", else: "-"}\t#{format(slot.retained_bytes)} held back"
    )
  end

  defp format(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  defp format(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format(bytes), do: "#{div(bytes, 1024)} kB"
end
