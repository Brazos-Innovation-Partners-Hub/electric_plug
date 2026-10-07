defmodule ElectricHost.Repo do
  @moduledoc "The application's database, whose connection electric_plug's Electric reads too."
  # No Ash functions in the database: the todo list needs none, and its migration is written by
  # hand.
  use AshPostgres.Repo, otp_app: :electric_host, warn_on_missing_ash_functions?: false

  @impl true
  def installed_extensions, do: []

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
