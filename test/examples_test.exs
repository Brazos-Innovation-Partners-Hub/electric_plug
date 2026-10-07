# electric_plug's worked examples (`ElectricPlug.Examples`), run in its world
# (`ElectricPlug.Test.World`): every breaks breaks its rule and every example passes; and the
# world proven to keep its contract.
defmodule ElectricPlug.ExamplesTest do
  use VStack.Examples.Case, world: ElectricPlug.Test.World, otp_app: :electric_plug
end

defmodule ElectricPlug.WorldTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  @tag timeout: 300_000
  test "the world keeps its contract" do
    assert :ok = VStack.Examples.WorldConformance.prove(ElectricPlug.Test.World)
  end
end
