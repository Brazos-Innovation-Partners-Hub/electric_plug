defmodule ElectricHost.Repo.Migrations.CreateTodos do
  use Ecto.Migration

  def change do
    create table(:todos, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :owner, :string, null: false, size: 80
      add :title, :string, null: false, size: 200
    end
  end
end
