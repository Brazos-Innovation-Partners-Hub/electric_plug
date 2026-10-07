# The design, the meaning and the worked examples are written in vstack_shared's DSLs without
# parentheses: their words come from vstack_shared's export, and the words of the examples'
# world are listed here.
example_words = [answered: 1, configured: 1, refused: 1, shape: 1]

[
  plugins: [Spark.Formatter],
  import_deps: [:vstack_shared],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: example_words
]
