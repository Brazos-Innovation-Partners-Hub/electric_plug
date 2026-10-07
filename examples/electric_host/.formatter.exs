[
  import_deps: [:ash, :ash_postgres, :plug, :vstack_shared],
  plugins: [Spark.Formatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "priv/repo/migrations/*.exs"
  ]
]
