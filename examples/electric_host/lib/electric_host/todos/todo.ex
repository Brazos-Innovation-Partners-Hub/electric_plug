defmodule ElectricHost.Todos.Todo do
  @moduledoc "A todo of one person's, read only by them."
  use Ash.Resource,
    domain: ElectricHost.Todos,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "todos"
    repo ElectricHost.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :owner, :string do
      description "Who the todo is for, by name."
      allow_nil? false
      public? true
      constraints max_length: 80
    end

    attribute :title, :string do
      description "What is to be done."
      allow_nil? false
      public? true
      constraints max_length: 200
    end
  end

  actions do
    read :read do
      description "The todos the actor may read: their own."
      primary? true
    end

    create :create do
      description "Writes down a todo for its owner."
      primary? true
      accept [:owner, :title]
    end
  end

  policies do
    policy action_type(:read) do
      description "A person reads their own todos, and nobody else's."
      authorize_if expr(owner == ^actor(:name))
    end

    policy action_type(:create) do
      description "Anyone may write down a todo."
      authorize_if always()
    end
  end

  resource do
    description "A todo of one person's: what they mean to do. Only its owner may read it."
  end
end
