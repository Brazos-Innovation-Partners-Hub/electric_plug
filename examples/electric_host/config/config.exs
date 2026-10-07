import Config

config :electric_host, ecto_repos: [ElectricHost.Repo], ash_domains: [ElectricHost.Todos]

config :electric_host, ElectricHost.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "electric_host_plug_#{config_env()}",
  pool_size: 5

# Where the application serves its shapes.
config :electric_host, port: String.to_integer(System.get_env("ELECTRIC_HOST_PORT", "4418"))

# electric_plug embeds Electric on the repository's connection. In test it makes a stream, a
# temporary slot and storage of its own for each run; Electric's own options go under
# `electric:`.
config :electric_plug,
  env: config_env(),
  repo: ElectricHost.Repo,
  electric: [db_pool_size: 2],
  log_level: :warning

config :logger, level: :warning

config :ash, default_string_length_count: :codepoints

config :spark, :formatter,
  remove_parens?: true,
  "Ash.Resource": [section_order: [:postgres, :attributes, :actions, :policies]],
  "VStack.Effects": [type: VStack.Effects.Declare]
