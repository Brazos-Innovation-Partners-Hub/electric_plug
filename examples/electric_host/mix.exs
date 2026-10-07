defmodule ElectricHost.MixProject do
  use Mix.Project

  # VStack by path: its design/library-standard branch, checked out beside this repository,
  # until the single push pins it by git again.
  @vstack "../../../vstack/packages"

  def project do
    [
      app: :electric_host,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {ElectricHost.Application, []}]
  end

  defp deps do
    [
      {:electric_plug, path: "../.."},
      # The same checkout electric_plug takes, to read the served shapes back over HTTP.
      {:electric_client, path: "../../../electric_client"},
      {:vstack_shared, path: "#{@vstack}/vstack_shared", override: true},
      {:vstack_dev, path: "#{@vstack}/vstack_dev", only: [:dev, :test], runtime: false},
      {:ash, "~> 3.0"},
      {:ash_postgres, "~> 2.13"},
      {:picosat_elixir, "~> 0.2"},
      {:bandit, "~> 1.5"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
