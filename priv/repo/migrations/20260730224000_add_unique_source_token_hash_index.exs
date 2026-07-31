defmodule Renga.Repo.Migrations.AddUniqueSourceTokenHashIndex do
  use Ecto.Migration

  def change do
    create unique_index(:sources, [:token_hash], where: "token_hash IS NOT NULL")
  end
end
