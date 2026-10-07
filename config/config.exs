import Config

# The design, the meaning and the worked examples (`ElectricPlug.Design`, `ElectricPlug.Meaning`,
# `ElectricPlug.Examples`) are formatted as the DSLs they are written in.
config :spark, :formatter,
  remove_parens?: true,
  "VStack.Library": [type: VStack.Library.Declare, extensions: [VStack.Effects]],
  "VStack.Rules": [type: VStack.Rules.Declare],
  "VStack.Examples": [type: VStack.Examples.Declare]
