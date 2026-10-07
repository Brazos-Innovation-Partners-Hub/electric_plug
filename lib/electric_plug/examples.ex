# Examples are written in vstack_shared's vocabulary, which needs Spark.
if Code.ensure_loaded?(VStack.Examples) do
  defmodule ElectricPlug.Examples do
    @moduledoc """
    `electric_plug`'s worked examples, as the library standard requires: each rule
    `ElectricPlug.Meaning` ships, shown broken; and what the plug does, run in its world
    (`ElectricPlug.Test.World`).

    The rules are broken on a todo list's host, written out as the facts its code and
    declarations would give (`given`): a controller, `MyApp.TodoShapes`, that serves its todos
    through `ElectricPlug`, beside a library's shape controller that serves the reads its own
    declarations name (`serves_read`, which EideticUI publishes). The worked examples read the shape a query is served as
    (`ElectricPlug.Shape`), what a node runs (`ElectricPlug.Node`) and what a node that runs
    nothing answers a request (`ElectricPlug.serve/4`, given a request the world builds from the
    params the example writes), on the world's todos: a `todos` table read through two schemas,
    one mapping every column (`ElectricPlug.Test.Todo`) and one leaving the owner out
    (`ElectricPlug.Test.PublicTodo`).
    """
    use VStack.Examples

    # ── the rules, each broken ──────────────────────────────────────────────────

    breaks :served_shapes_name_their_read,
      in: ElectricPlug,
      description:
        "A controller that serves its todos through ElectricPlug and declares no read, beside a library that serves the reads its own declarations name (a notes page's): the controller is not one of that library's, so nothing shows that a policy decides its query, which could hold every todo of every owner.",
      given: [
        calls("MyApp.TodoShapes", ElectricPlug),
        serves_read("EideticUI.ShapeController", "MyApp.Notes.Note#actions.read")
      ],
      names: [serves_shapes("MyApp.TodoShapes")]

    breaks :served_reads_are_policed,
      in: ElectricPlug,
      description:
        "A library's shape controller that serves a notes read its declarations name, and a todo controller that declares its todo read: neither resource has policies, so nothing decides who may read which note or todo, and every client is served every row the query keeps.",
      given: [
        calls("EideticUI.ShapeController", ElectricPlug),
        serves_read("EideticUI.ShapeController", "MyApp.Notes.Note#actions.read"),
        element("MyApp.Notes.Note#actions.read", "read"),
        in_extension("MyApp.Notes.Note#actions.read", "Ash.Resource.Dsl"),
        in_module("MyApp.Notes.Note#actions.read", "MyApp.Notes.Note"),
        property("MyApp.Notes.Note", "extensions", ["Ash.Resource.Dsl", "AshPostgres.DataLayer"]),
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
      names: [
        served_read("EideticUI.ShapeController", "MyApp.Notes.Note#actions.read"),
        served_read("MyApp.TodoShapes", "MyApp.Todos.Todo#actions.read")
      ]

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

    example :a_disabled_node_answers_unavailable do
      description "A node configured to run nothing answers a shape request 503 without serving a row, and asks the client to come back much later, since it serves only once configured and restarted."
      covers ElectricPlug

      given do
        configured mode: :disabled
      end

      act ElectricPlug.serve(%{"offset" => "-1", "table" => "secrets"}, ElectricPlug.Test.Todo)

      expect do
        responded 503, retry_after: "300"
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

    example :revoking_a_share_cuts_the_streams do
      description "Revoking a share flushes the person's cached filter, ends their waiting poll and closes their channel joins."
      covers ElectricPlug.Revocation
      act ElectricPlug.Revocation.revoke(%{person: "u-1", record: "space-9"}, [])

      expect do
        shaped(flushed: 1, polls_ended: 1, joins_closed: 1)
      end
    end

    example :a_revoked_reader_gets_no_held_rows do
      description "A long poll that was waiting delivers none of the rows it held when its reader was revoked."
      covers ElectricPlug.Revocation
      act ElectricPlug.Revocation.revoke(%{person: "u-1"}, [])

      expect do
        shaped(rows_delivered_after: 0)
      end
    end

    example :the_calling_changes_are_named do
      description "The authority changes that call revocation are named by the host."
      covers ElectricPlug.Revocation
      act ElectricPlug.Revocation.watching(:host)

      expect do
        listing([:grant_revoked, :group_member_removed, :role_revoked])
      end
    end

    example :explicit_connection_options_win do
      description "With a repository and explicit connection options both set, Electric replicates over the options."
      covers ElectricPlug.Config.Connection

      act ElectricPlug.Config.Connection.choose(
            repo: :my_repo,
            connection_opts: [hostname: "db-direct", port: 5432]
          )

      expect do
        shaped(source: :connection_opts)
      end
    end

    example :the_repository_is_used_when_nothing_else_is_given do
      description "With only a repository, Electric uses its connection."
      covers ElectricPlug.Config.Connection
      act ElectricPlug.Config.Connection.choose(repo: :my_repo)

      expect do
        shaped(source: :repo)
      end
    end

    example :the_source_is_told_at_boot do
      description "The source of the connection is named for the boot log."
      covers ElectricPlug.Config.Connection

      act ElectricPlug.Config.Connection.source(
            repo: :my_repo,
            connection_opts: [hostname: "db-direct"]
          )

      expect do
        answered(:connection_opts)
      end
    end
  end
end
