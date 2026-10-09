defmodule Renga.ScratchMigrations do
  @moduledoc """
  Runs the repository's migrations against a scratch database, for tests that
  exercise a migration itself without touching the shared test database.

  `mix test` has already loaded every migration module while migrating the
  shared test database, so compiling them again for the scratch database
  would warn "redefining module" once per migration. Those redefinitions are
  the point here, so the warning is switched off while they compile.
  """

  @doc "Runs `Ecto.Migrator.run/4` on the scratch repository named `repo`."
  def run(repo, direction, opts) do
    path = Ecto.Migrator.migrations_path(Renga.Repo)
    opts = Keyword.merge([dynamic_repo: repo, log: false], opts)

    without_module_conflict_warnings(fn ->
      Ecto.Migrator.run(Renga.Repo, path, direction, opts)
    end)
  end

  defp without_module_conflict_warnings(fun) do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      fun.()
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end
end
