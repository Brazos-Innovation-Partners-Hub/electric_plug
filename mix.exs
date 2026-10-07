defmodule ElectricPlug.MixProject do
  use Mix.Project

  # VStack by path: its design/library-standard branch, checked out beside this repository,
  # until the single push pins it by git again.
  @vstack "../vstack/packages"

  @version "0.3.0"
  @source "https://github.com/Brazos-Innovation-Partners-Hub/electric_plug"

  def project do
    [
      app: :electric_plug,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [precommit: &precommit/1],
      description:
        "Serves Electric's shape-log protocol for an authorised Ecto query, with Electric embedded",
      source_url: @source,
      docs: [main: "ElectricPlug", extras: ["README.md", "CHANGELOG.md"]],
      package: [licenses: ["Apache-2.0"], links: %{"GitHub" => @source}]
    ]
  end

  # The worked examples' world and the schemas they read are the tests'.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def cli, do: [preferred_envs: [precommit: :test]]

  def application do
    [extra_applications: [:logger], mod: {ElectricPlug.Application, []}]
  end

  # The gate: this project formatted, compiled with warnings as errors and tested, the tests
  # against a real PostgreSQL included (`ELECTRIC_PLUG_DB=1`); then the library standard against
  # the committed baseline and the usage rules written from the design; then the reference
  # application, its suite and the rules its libraries ship.
  defp precommit(_args) do
    for args <- [
          ~w(format --check-formatted),
          ~w(compile --warnings-as-errors),
          ~w(test),
          ~w(vstack.library --app electric_plug --baseline design/facts.json),
          ~w(vstack.usage_rules --app electric_plug --file usage-rules.md --check)
        ],
        do: run!(".", args, [{"MIX_ENV", "test"}, {"ELECTRIC_PLUG_DB", "1"}])

    for args <- [
          ~w(deps.get),
          ~w(format --check-formatted),
          ~w(compile --warnings-as-errors),
          ~w(test),
          ~w(vstack.rules --code)
        ],
        do: run!("examples/electric_host", args, [{"MIX_ENV", "test"}])
  end

  defp run!(dir, args, env) do
    path = Path.expand(dir, __DIR__)
    {_, status} = System.cmd("mix", args, cd: path, into: IO.stream(), env: env)

    if status != 0 do
      Mix.raise("#{path}: mix #{Enum.join(args, " ")} failed")
    end
  end

  defp deps do
    [
      {:vstack_shared, path: "#{@vstack}/vstack_shared", override: true},
      {:vstack_dev, path: "#{@vstack}/vstack_dev", only: [:dev, :test], runtime: false},
      {:electric, "~> 1.8"},
      # Electric's own Elixir client, carried by us because upstream's stops at Electric 1.6.
      # By path from its design/library-standard branch, checked out beside this repository,
      # so its design is read with this one's; the single push pins it by git again.
      {:electric_client, path: "../electric_client"},
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
