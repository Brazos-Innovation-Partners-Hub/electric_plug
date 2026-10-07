defmodule ElectricHostTest do
  @moduledoc """
  electric_plug proved against a real host: an Ash todo list whose read only lets a person see
  their own todos, served through `ElectricPlug.serve/4` on a real PostgreSQL with Electric
  embedded, and read back over HTTP with `electric_client` as a browser's client would.
  """
  use ExUnit.Case, async: false

  alias Electric.Client
  alias Electric.Client.Message.ChangeMessage

  @moduletag timeout: 180_000

  setup_all do
    :ok = ElectricPlug.Node.await_ready(120_000)
    :ok
  end

  test "this node serves the stream itself" do
    assert ElectricPlug.Node.mode() == :embedded
    assert ElectricPlug.Node.serving() == :active
    assert ElectricPlug.Node.status() == :active
  end

  test "a person is served their own todos, and nothing of anyone else's" do
    alice = person("alice")
    bob = person("bob")
    write(alice, "Buy milk")
    write(bob, "Pay rent")

    assert titles(alice) == ["Buy milk"]
    assert titles(bob) == ["Pay rent"]
  end

  test "a client that asks for another table, every row and more columns is served only the query" do
    alice = person("alice")
    bob = person("bob")
    write(alice, "Buy milk")
    write(bob, "Pay rent")

    wider = %{table: "todos", where: "true", columns: "id,owner,title"}
    assert titles(alice, wider) == ["Buy milk"]
  end

  test "someone with no todos is served none" do
    write(person("alice"), "Buy milk")
    assert titles(person("carol")) == []
  end

  test "a change to a person's todos reaches them live, and another's does not" do
    alice = person("alice")
    bob = person("bob")
    write(alice, "Buy milk")

    reader =
      Task.async(fn ->
        alice
        |> client()
        |> Client.stream(live: true)
        |> Stream.flat_map(fn
          %ChangeMessage{value: %{"title" => title}} -> [title]
          _other -> []
        end)
        |> Enum.reduce_while([], fn
          "Write report", seen -> {:halt, Enum.reverse(["Write report" | seen])}
          title, seen -> {:cont, [title | seen]}
        end)
      end)

    # Once the reader has read the todo there is and waits for changes.
    Process.sleep(1_000)
    write(bob, "Pay rent")
    write(alice, "Write report")

    assert Task.await(reader, 60_000) == ["Buy milk", "Write report"]
  end

  defp person(name), do: "#{name}-#{System.unique_integer([:positive])}"

  defp write(owner, title) do
    Ash.create!(ElectricHost.Todos.Todo, %{owner: owner, title: title}, actor: %{name: owner})
  end

  defp client(actor, params \\ %{}) do
    port = Application.fetch_env!(:electric_host, :port)

    Client.new!(
      endpoint: "http://127.0.0.1:#{port}/shapes/todos",
      params: params,
      fetch: {Client.Fetch.HTTP, headers: [{"x-actor", actor}], timeout: 30}
    )
  end

  defp titles(actor, params \\ %{}) do
    actor
    |> client(params)
    |> Client.stream(live: false)
    |> Enum.flat_map(fn
      %ChangeMessage{value: %{"title" => title}} -> [title]
      _other -> []
    end)
  end
end
