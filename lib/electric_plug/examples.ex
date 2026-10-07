# Examples are written in vstack_shared's vocabulary, which needs Spark.
if Code.ensure_loaded?(VStack.Examples) do
  defmodule ElectricPlug.Examples do
    @moduledoc """
    `electric_plug`'s worked examples, as the library standard requires: each rule
    `ElectricPlug.Meaning` ships, shown broken; and what the plug does, run in its world
    (`ElectricPlug.Test.World`).

    The rules are broken on a todo list's host, written out as the facts its code and
    declarations would give (`given`): a controller, `MyApp.TodoShapes`, that serves its todos
    through `ElectricPlug`. The worked examples read the shape a query is served as
    (`ElectricPlug.Shape`) and what a node runs (`ElectricPlug.Node`), on the world's todos: a
    `todos` table read through two schemas, one mapping every column (`ElectricPlug.Test.Todo`)
    and one leaving the owner out (`ElectricPlug.Test.PublicTodo`).
    """
    use VStack.Examples

    # ── the rules, each broken ──────────────────────────────────────────────────

    breaks :served_shapes_name_their_read,
      in: ElectricPlug.Design,
      description:
        "A controller that serves its todos through ElectricPlug and declares no read: its query could hold every todo of every owner, and nothing shows that a policy decides it.",
      given: [calls("MyApp.TodoShapes", ElectricPlug)],
      names: [serves_shapes("MyApp.TodoShapes")]

    breaks :served_reads_are_policed,
      in: ElectricPlug.Design,
      description:
        "A controller that serves the read of a todo resource with no policies: the read is named, but nothing decides who may read which todo, so every client is served every todo the query keeps.",
      given: [
        calls("MyApp.TodoShapes", ElectricPlug),
        element("MyApp.TodoShapes#effects.MyApp.Todos.Todo", "calls"),
        in_extension("MyApp.TodoShapes#effects.MyApp.Todos.Todo", "VStack.Effects"),
        part_of("MyApp.TodoShapes#effects.MyApp.Todos.Todo", "MyApp.TodoShapes"),
        property("MyApp.TodoShapes#effects.MyApp.Todos.Todo", "class", :read),
        property("MyApp.TodoShapes#effects.MyApp.Todos.Todo", "resource", "MyApp.Todos.Todo"),
        property("MyApp.TodoShapes#effects.MyApp.Todos.Todo", "action", :read),
        element("MyApp.Todos.Todo#actions.read", "read"),
        in_extension("MyApp.Todos.Todo#actions.read", "Ash.Resource.Dsl"),
        in_module("MyApp.Todos.Todo#actions.read", "MyApp.Todos.Todo"),
        property("MyApp.Todos.Todo", "extensions", ["Ash.Resource.Dsl", "AshPostgres.DataLayer"])
      ],
      names: [served_read("MyApp.TodoShapes", "MyApp.Todos.Todo#actions.read")]

    # ── the shape a query is served as ──────────────────────────────────────────

    example :a_schema_is_served_as_its_table do
      description "A schema module is served as its table, with every column it maps and no where clause: all of the table's rows, and only those columns."
      covers ElectricPlug.Shape
      act ElectricPlug.Shape.params(ElectricPlug.Test.Todo)

      expect do
        shape table: "todos", columns: ["id", "owner", "title"]
      end
    end

    example :columns_narrow_the_shape do
      description "A host that gives fewer columns than its query maps is served exactly those."
      covers ElectricPlug.Shape
      act ElectricPlug.Shape.params(ElectricPlug.Test.Todo, columns: ["id", "title"])

      expect do
        shape table: "todos", columns: ["id", "title"]
      end
    end

    example :columns_never_widen_the_shape do
      description "A column the query does not map is refused, even one its table has: the columns a host gives only narrow what the query allows."
      covers ElectricPlug.Shape

      act ElectricPlug.Shape.params(ElectricPlug.Test.PublicTodo,
            columns: ["id", "title", "owner"]
          )

      expect do
        refused "owner"
      end
    end

    example :a_where_beside_the_query_is_refused do
      description "A where clause given beside the query is refused rather than put in place of the query's: only the query says which rows are served."
      covers ElectricPlug.Shape
      act ElectricPlug.Shape.params(ElectricPlug.Test.Todo, where: "true")

      expect do
        refused "where"
      end
    end

    # ── what a node runs ────────────────────────────────────────────────────────

    example :a_node_with_no_database_says_why do
      description "A node given neither a repository nor a connection runs no Electric, and says that it is disabled and why."
      covers ElectricPlug.Node

      given do
        configured repo: nil, connection_opts: nil
      end

      act ElectricPlug.Node.mode()

      expect do
        answered {:disabled, "no `repo` or `connection_opts` configured"}
      end
    end

    example :a_disabled_node_serves_nothing do
      description "A node configured to run nothing neither serves the stream nor forwards to a node that does."
      covers ElectricPlug.Node

      given do
        configured mode: :disabled
      end

      act ElectricPlug.Node.serving()

      expect do
        answered :unavailable
      end
    end
  end
end
