defmodule ElectricHost.Todos do
  @moduledoc "A todo list: each person's todos, which only they may read."
  use Ash.Domain

  domain do
    description "A todo list: each person's todos, which only they may read."
  end

  resources do
    resource ElectricHost.Todos.Todo
  end
end
