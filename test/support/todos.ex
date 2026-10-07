defmodule ElectricPlug.Test.Todo do
  @moduledoc """
  A todo, every column of the `todos` table mapped: what the worked examples serve whole.
  """
  use Ecto.Schema

  schema "todos" do
    field :owner, :string
    field :title, :string
  end
end

defmodule ElectricPlug.Test.PublicTodo do
  @moduledoc """
  A todo read without its owner: the `todos` table with the owner column left out, so a host
  that serves it cannot be asked for the owner.
  """
  use Ecto.Schema

  schema "todos" do
    field :title, :string
  end
end
