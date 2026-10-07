defmodule ElectricHost.TodoShapes do
  @moduledoc """
  Serves a person their own todos, live, as Electric's shape log: the query is the todo read
  its policy decides for them, and a client's own table, where clause or columns change
  nothing.
  """
  use VStack.Effects

  alias ElectricHost.Todos.Todo

  effects do
    calls Todo, :read,
      class: :read,
      doc: "The read whose query is served: its policy keeps only the actor's own todos."
  end

  @doc "Serves `name`'s todos to `conn`, from the request's `params` (its place in the log)."
  @spec show(Plug.Conn.t(), map(), String.t()) :: Plug.Conn.t()
  def show(conn, params, name) do
    {:ok, %{query: query}} =
      Todo
      |> Ash.Query.for_read(:read, %{}, actor: %{name: name})
      |> Ash.data_layer_query()

    ElectricPlug.serve(conn, params, query)
  end
end
