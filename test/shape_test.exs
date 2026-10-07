defmodule ElectricPlug.ShapeTest do
  @moduledoc """
  The shape a query is served as: the query's own, narrowed by `columns:` and never widened,
  with a where or params beside it refused rather than put in its place.
  """
  use ExUnit.Case, async: true

  import Ecto.Query

  alias ElectricPlug.Shape
  alias ElectricPlug.Test.{PublicTodo, Todo}

  test "a schema is its table and every column it maps" do
    assert {:ok, params} = Shape.params(Todo)
    assert params[:table] == "todos"
    assert params[:columns] == ["id", "owner", "title"]
    refute Keyword.has_key?(params, :where)
  end

  test "a query's where is the shape's, and `replica:` changes only what an update carries" do
    query = from(t in Todo, where: t.owner == ^"alice")
    assert {:ok, params} = Shape.params(query, replica: :full)
    assert params[:where] == ~s|("owner" = 'alice')|
    assert params[:replica] == :full
  end

  test "`columns:` narrows to columns the query selects" do
    assert {:ok, params} = Shape.params(Todo, columns: ["id", "title"])
    assert params[:columns] == ["id", "title"]
  end

  test "`columns:` never widens: a column the query does not select is refused, even one its table has" do
    assert {:error, reason} = Shape.params(PublicTodo, columns: ["id", "title", "owner"])
    assert reason =~ "owner is not a column the query selects"

    query = from(t in Todo, select: [:id, :title])
    assert {:error, reason} = Shape.params(query, columns: ["id", "owner"])
    assert reason =~ "owner"
  end

  test "a where or params beside the query is refused, never put in its place" do
    query = from(t in Todo, where: t.owner == ^"alice")
    assert {:error, reason} = Shape.params(query, where: "true")
    assert reason =~ "where is not an option"
    assert {:error, reason} = Shape.params(query, params: %{1 => "bob"})
    assert reason =~ "params is not an option"
  end

  test "an option the shape does not know is refused" do
    assert {:error, reason} = Shape.params(Todo, table: "secrets")
    assert reason =~ ":table is not an option"
  end

  test "a query that cannot be one shape is refused" do
    query = from(t in Todo, join: o in PublicTodo, on: o.id == t.id)
    assert {:error, reason} = Shape.params(query)
    assert reason =~ "cannot be served as one shape"
  end

  test "serve/4 refuses a widening option before anything is served" do
    conn = Plug.Test.conn(:get, "/shape?offset=-1")

    assert_raise ArgumentError, ~r/owner is not a column the query selects/, fn ->
      ElectricPlug.serve(conn, %{"offset" => "-1"}, PublicTodo, columns: ["id", "owner"])
    end
  end
end
