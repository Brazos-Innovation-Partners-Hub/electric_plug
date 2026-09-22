defmodule ElectricPlug.Shape do
  @moduledoc false
  # An Ecto query as the parameters of a predefined shape: table (and schema), where,
  # columns, replica. Electric's client library does the translation; a query that
  # cannot be one shape — a join, an aggregate — raises there and is the caller's to
  # refuse before it gets here.

  @doc "Shape parameters for a schema module or an `Ecto.Query`."
  @spec params(term(), keyword()) :: keyword()
  def params(queryable, opts \\ []) do
    shape_opts = Keyword.take(opts, [:replica, :columns, :where, :params])

    queryable
    |> Electric.Client.EctoAdapter.shape!(shape_opts)
    |> Electric.Client.ShapeDefinition.params(format: :keyword)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
