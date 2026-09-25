defmodule ElectricPlug.RemoteTest do
  @moduledoc """
  A long poll served in a process of its own and watched: its own answer when it comes;
  503 at once when the node's tenure ends; 403 at once when the caller is sent the
  interrupt it named — a host ending an ejected actor's access while their long poll
  waits, rather than on their next request.
  """
  use ExUnit.Case, async: true

  alias ElectricPlug.Remote

  defp slow(test),
    do: fn -> send(test, {:serving, self()}) && Process.sleep(10_000) && {200, [], "late"} end

  test "answers what the request answers" do
    assert {200, [], "rows"} = Remote.watch(fn -> {200, [], "rows"} end, nil, nil)
    assert {200, [], "rows"} = Remote.watch(fn -> {200, [], "rows"} end, nil, {:eject, "a"})
  end

  test "the interrupt it was given answers at once, 403, and ends the waiting request" do
    test = self()
    task = Task.async(fn -> Remote.watch(slow(test), nil, {:eject, "ada"}) end)
    assert_receive {:serving, worker}, 1_000
    ref = Process.monitor(worker)

    send(task.pid, {:eject, "ada"})
    assert {403, headers, body} = Task.await(task, 1_000)
    assert {"cache-control", "no-store"} in headers
    assert Jason.decode!(body) == %{"message" => "access to this shape has ended"}
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
  end

  test "another message, or another actor's interrupt, does not end it" do
    test = self()

    task =
      Task.async(fn ->
        Remote.watch(
          fn -> send(test, :serving) && Process.sleep(300) && {200, [], "rows"} end,
          nil,
          {:eject, "ada"}
        )
      end)

    assert_receive :serving, 1_000
    send(task.pid, {:eject, "grace"})
    send(task.pid, :something_else)
    assert {200, [], "rows"} = Task.await(task, 2_000)
  end

  test "a tenure that ends answers at once, 503" do
    test = self()
    tenure = spawn(fn -> Process.sleep(:infinity) end)
    task = Task.async(fn -> Remote.watch(slow(test), tenure, nil) end)
    assert_receive {:serving, _worker}, 1_000

    Process.exit(tenure, :kill)
    assert {503, _headers, _body} = Task.await(task, 1_000)
  end
end
