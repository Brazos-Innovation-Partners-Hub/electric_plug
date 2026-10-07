# Rules are written in vstack_shared's vocabulary, which needs Spark.
if Code.ensure_loaded?(VStack.Rules) do
  defmodule ElectricPlug.Meaning do
    @moduledoc """
    What serving a shape through `electric_plug` means, as facts for rules, and the rules it
    ships to every host that depends on it.

    `ElectricPlug.serve/4` sends a client the shape log of the query its caller passes and
    nothing wider: the query's table, the rows its where clause keeps and its columns. A
    client's own `table`, `where` and `columns` are ignored, and the options a host may add only
    narrow the columns. So what a client may see is decided where the query is built, by the
    host, and these facts follow that decision to where a rule can judge it:

      * `serves_shapes(m)`: code in module `m`, not a test's, serves shape logs through
        `ElectricPlug` (it calls `ElectricPlug`, whose one function is `serve/4`);
      * `served_read(m, read)`: `m`, which serves shape logs, declares in its effects the Ash
        read whose query it serves (`calls Resource, :action, class: :read`), or its library
        says it serves `read`, which that library's declarations name (`serves_read`, which a
        library serving its hosts' reads publishes: EideticUI);
      * `names_a_read(m)`: `m` names at least one such read;
      * `policed_read(read)`: read action `read` is decided by its resource's policies (its
        resource uses `Ash.Policy.Authorizer`).

    The two rules fail closed. A module that serves shape logs and names no read breaks the
    first, whatever its query happens to hold; one whose read no policy decides breaks the
    second. Nothing is taken as authorised because nothing said otherwise. A host whose
    authority cannot be shown this way (an Ecto query its own code narrows, or one built from
    a read chosen as it runs) holds an exception naming the decision that accepts it.
    """
    use VStack.Rules

    rules do
      define serves_shapes(m) do
        description "Code in module m serves shape logs through ElectricPlug: what it sends a client is exactly the rows and columns of the query m passes, so m is where what a client may see is decided. A module compiled from tests serves no client and is left out."

        where do
          calls(m, ElectricPlug)
          not test_module(m)
        end
      end

      define served_read(m, read) do
        description "Module m, which serves shape logs, declares the Ash read whose query it serves: an action it calls, classed as a read, in its own effects (`calls Resource, :action, class: :read`)."

        where do
          serves_shapes(m)
          element(e, "calls")
          in_extension(e, "VStack.Effects")
          part_of(e, m)
          not property(e, "by", _by)
          property(e, "class", :read)
          property(e, "resource", resource)
          property(e, "action", action)
          concat(read, resource, "#actions.", action)
        end
      end

      define served_read(m, read) do
        description "The same, declared for module m elsewhere, with `by:`."

        where do
          serves_shapes(m)
          element(e, "calls")
          in_extension(e, "VStack.Effects")
          property(e, "by", m)
          property(e, "class", :read)
          property(e, "resource", resource)
          property(e, "action", action)
          concat(read, resource, "#actions.", action)
        end
      end

      # A library that serves reads its own declarations name (EideticUI's shape controller
      # serves each live projection's read) says so; its module then names its reads that way.
      awaits :serves_read,
        from:
          "EideticUI's published facts (a library that serves reads its own declarations name)",
        description:
          "serves_read(m, read): module m serves read, which its library's declarations name."

      define served_read(m, read) do
        description "Module m, which serves shape logs, serves read as its library's own declarations name it: a library that serves the reads its hosts declare (`serves_read`)."

        where do
          serves_shapes(m)
          serves_read(m, read)
        end
      end

      define names_a_read(m) do
        description "Module m, which serves shape logs, names at least one Ash read whose query it serves."

        where do
          served_read(m, _read)
        end
      end

      define policed_read(read) do
        description "Read action read is decided by its resource's policies (the resource uses `Ash.Policy.Authorizer`), so the query it builds for an actor keeps only the records that actor may read."

        where do
          element(read, "read")
          in_extension(read, "Ash.Resource.Dsl")
          in_module(read, resource)
          property(resource, "extensions", extensions)
          member(Ash.Policy.Authorizer, extensions)
        end
      end

      rule :served_shapes_name_their_read do
        description "Every module that serves shape logs through ElectricPlug names, in its effects, the Ash read whose query it serves: a served query nothing accounts for breaks this rule rather than being taken as authorised"

        never do
          serves_shapes(m)
          not names_a_read(m)
        end
      end

      rule :served_reads_are_policed do
        description "Every read whose query a module serves through ElectricPlug is decided by its resource's policies: a read no policy decides hands every client every record its query keeps, so it breaks this rule however narrow the query looks"

        whenever do
          served_read(m, read)
        end

        must do
          policed_read(read)
        end
      end
    end
  end
end
