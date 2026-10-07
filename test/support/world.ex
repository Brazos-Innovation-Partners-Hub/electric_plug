defmodule ElectricPlug.Test.World do
  @moduledoc """
  The world `electric_plug`'s worked examples (`ElectricPlug.Examples`) run in: this library's
  application as the suite configures it (no database, so it runs no Electric), the todo
  schemas, a request built from the params an example writes, and these words.
  """
  use VStack.Examples.LibraryWorld

  @keys [:mode, :repo, :connection_opts, :cluster, :replication_stream_id, :electric]

  @impl VStack.Examples.World
  def examples, do: [ElectricPlug.Examples]

  @impl VStack.Examples.LibraryWorld
  def words do
    [
      configured:
        "Given: `config :electric_plug` holds these keys and values (a nil value: the key is not set), read afresh.",
      shape:
        "The act gave `{:ok, params}`: the shape's parameters as Electric is given them, whose `table:`, `where:`, `columns:` and `replica:` are the ones given.",
      refused:
        "The act gave `{:error, reason}`, and the reason names this: an option or a column refused.",
      answered: "The act answered exactly this.",
      responded:
        "The request was answered with this status, and with these response headers (`retry_after:` is `retry-after`)."
    ]
  end

  @impl VStack.Examples.LibraryWorld
  def start(context) do
    Enum.each(@keys, &Application.delete_env(:electric_plug, &1))
    ElectricPlug.Node.reset_configuration()
    context
  end

  @impl VStack.Examples.LibraryWorld
  def arrange(:configured, [], settings, context) do
    for {key, value} <- settings do
      if is_nil(value),
        do: Application.delete_env(:electric_plug, key),
        else: Application.put_env(:electric_plug, key, value)
    end

    ElectricPlug.Node.reset_configuration()
    context
  end

  # A request to serve, as a host's controller is given it: built from the params the example
  # writes, then served with the query it names.
  @impl VStack.Examples.LibraryWorld
  def perform({ElectricPlug, :serve}, [params, queryable], _context) do
    conn =
      Plug.Test.conn(:get, "/shape?" <> URI.encode_query(params))
      |> Plug.Conn.fetch_query_params()

    {:ok, ElectricPlug.serve(conn, conn.query_params, queryable)}
  end

  def perform(_declaration, _args, _context), do: :none

  @impl VStack.Examples.LibraryWorld
  def judge(:shape, [], fields, %{result: {:ok, params}}) when is_list(params) do
    wrong =
      for {field, want} <- fields,
          Keyword.get(params, field) != want,
          do: "#{field} is #{inspect(Keyword.get(params, field))}, not #{inspect(want)}"

    if wrong == [], do: :ok, else: {:error, Enum.join(wrong, "; ")}
  end

  def judge(:shape, [], _fields, %{result: result}),
    do: {:error, "the act answered #{inspect(result)}, not {:ok, params}"}

  def judge(:refused, [named], [], %{result: {:error, reason}}) when is_binary(reason) do
    if String.contains?(reason, named),
      do: :ok,
      else: {:error, "it was refused, but its reason does not name #{inspect(named)}: #{reason}"}
  end

  def judge(:refused, [_named], [], %{result: result}),
    do: {:error, "the act answered #{inspect(result)}: it was not refused"}

  def judge(:answered, [expected], [], %{result: result}) do
    if result == expected,
      do: :ok,
      else: {:error, "the act answered #{inspect(result)}, not #{inspect(expected)}"}
  end

  def judge(:responded, [status], headers, %{result: %Plug.Conn{} = conn}) do
    wrong =
      [if(conn.status != status, do: "the status is #{conn.status}, not #{status}")] ++
        for {name, want} <- headers,
            header = name |> Atom.to_string() |> String.replace("_", "-"),
            Plug.Conn.get_resp_header(conn, header) != [want],
            do:
              "#{header} is #{inspect(Plug.Conn.get_resp_header(conn, header))}, not #{inspect(want)}"

    case Enum.reject(wrong, &is_nil/1) do
      [] -> :ok
      wrong -> {:error, Enum.join(wrong, "; ")}
    end
  end

  def judge(:responded, [_status], _headers, %{result: result}),
    do: {:error, "the act answered #{inspect(result)}, not a response"}
end
