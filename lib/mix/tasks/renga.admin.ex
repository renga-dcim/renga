defmodule Mix.Tasks.Renga.Admin do
  @shortdoc "Runs a renga-admin release command in development"

  @moduledoc """
  Runs the same commands as a release's `bin/renga-admin`, such as

      mix renga.admin operator-tokens create --name ci --scope organizations:read

  See `Renga.Release.CLI`.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(argv) do
    status = Renga.Release.with_repos(fn -> Renga.Release.CLI.run(argv) end)
    if status != 0, do: exit({:shutdown, status})
  end
end
