defmodule ElectricPlug.Shape do
  @moduledoc """
  The shape `ElectricPlug.serve/4` serves for a query, as Electric is given it: the query's
  table (and its schema), the rows its where clause keeps, its columns, and whether an update
  carries the whole row.

  The query alone says which rows are served. Of the options a host may give beside it,
  `replica:` (`:default` or `:full`) changes only what an update carries, and `columns:` can
  only narrow: every column it names must be one the query selects (or, for a query that
  selects no columns of its own, one of its table's). A `where:` or `params:` beside the query
  is refused rather than put in its place, and so is any other option. A query that cannot be
  one shape (a join, an aggregate, a limit) is refused too.

      ElectricPlug.Shape.params(from(t in Todo, where: t.owner_id == ^user_id), columns: ["id", "title"])
      #=> {:ok, [table: "todos", where: ~s|("owner_id" = '...')|, columns: ["id", "title"]]}

  A host that must know what a query will be served as before it serves it asks here.
  """

  alias Electric.Client.EctoAdapter
  alias Electric.Client.ShapeDefinition

  @options [:replica, :columns]

  @typedoc "A shape as Electric's embedded API is given it: table, namespace, where, columns, replica."
  @type params :: keyword()

  @doc """
  The shape `serve/4` serves for `queryable` (a schema module or an `Ecto.Query`) with the
  options given (`replica:`, `columns:`): `{:ok, params}`, or `{:error, reason}` when an option
  would widen the query or the query cannot be one shape.
  """
  @spec params(Ecto.Queryable.t(), keyword()) :: {:ok, params()} | {:error, String.t()}
  def params(queryable, opts \\ []) when is_list(opts) do
    with :ok <- options(opts),
         {:ok, shape} <- shape(queryable, Keyword.take(opts, [:replica])),
         {:ok, shape} <- narrow(shape, Keyword.get(opts, :columns)) do
      {:ok,
       shape
       |> ShapeDefinition.params(format: :keyword)
       |> Enum.reject(fn {_key, value} -> is_nil(value) end)}
    end
  end

  defp options(opts) do
    case Keyword.keys(opts) -- @options do
      [] ->
        :ok

      [key | _] when key in [:where, :params] ->
        {:error,
         "#{key} is not an option of a served shape: the query alone says which rows are served"}

      [key | _] ->
        {:error,
         "#{inspect(key)} is not an option of a served shape: give `replica:` or `columns:`"}
    end
  end

  defp shape(queryable, opts) do
    {:ok, EctoAdapter.shape!(queryable, opts)}
  rescue
    error ->
      {:error, "the query cannot be served as one shape: " <> Exception.message(error)}
  end

  defp narrow(shape, nil), do: {:ok, shape}

  defp narrow(%ShapeDefinition{columns: nil} = shape, columns) when is_list(columns),
    do: {:ok, %{shape | columns: columns}}

  defp narrow(%ShapeDefinition{columns: allowed} = shape, columns) when is_list(columns) do
    case Enum.reject(columns, &(&1 in allowed)) do
      [] ->
        {:ok, %{shape | columns: columns}}

      wider ->
        {:error,
         "#{Enum.join(wider, ", ")} #{if length(wider) == 1, do: "is not a column", else: "are not columns"} the query selects (#{Enum.join(allowed, ", ")}): `columns:` only narrows the query"}
    end
  end

  defp narrow(_shape, other),
    do: {:error, "columns: is a list of column names, got #{inspect(other)}"}
end
