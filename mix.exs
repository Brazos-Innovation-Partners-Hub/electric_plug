defmodule ElectricPlug.MixProject do
  use Mix.Project

  @version "0.2.4"
  @source "https://github.com/Brazos-Innovation-Partners-Hub/electric_plug"

  def project do
    [
      app: :electric_plug,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Serves Electric's shape-log protocol for an authorised Ecto query, with Electric embedded",
      source_url: @source,
      docs: [main: "ElectricPlug", extras: ["README.md", "CHANGELOG.md"]],
      package: [licenses: ["Apache-2.0"], links: %{"GitHub" => @source}]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {ElectricPlug.Application, []}]
  end

  defp deps do
    [
      {:electric, "~> 1.8"},
      # Electric's own Elixir client, carried by us because upstream's stops at Electric 1.6.
      {:electric_client,
       git: "https://github.com/Brazos-Innovation-Partners-Hub/electric_client.git",
       ref: "7590315914d5226080f7e94be6697b3f3e0adec4"},
      # Electric's generated protobuf code must match the protox runtime; the version
      # Hex resolves for Electric alone does not.
      {:protox, "~> 2.0.10"},
      {:plug, "~> 1.15"},
      {:ecto, "~> 3.10", optional: true},
      {:ecto_sql, "~> 3.10", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
