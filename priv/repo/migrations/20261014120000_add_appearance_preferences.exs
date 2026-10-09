defmodule Renga.Repo.Migrations.AddAppearancePreferences do
  @moduledoc """
  Stores each person's theme, accent, and density so they follow them
  across devices, and an organization's default accent for members who
  have not chosen one (RFD 8, "Visual design").
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :theme, :text, null: false, default: "system"
      # Null follows the organization's default accent.
      add :accent, :text
      add :density, :text, null: false, default: "comfortable"
    end

    create constraint(:users, :users_valid_theme, check: "theme IN ('system', 'light', 'dark')")

    create constraint(:users, :users_valid_accent,
             check: "accent IS NULL OR accent IN ('copper', 'petrol', 'cobalt', 'iris', 'mono')"
           )

    create constraint(:users, :users_valid_density,
             check: "density IN ('comfortable', 'compact')"
           )

    alter table(:organizations) do
      add :default_accent, :text, null: false, default: "copper"
    end

    create constraint(:organizations, :organizations_valid_default_accent,
             check: "default_accent IN ('copper', 'petrol', 'cobalt', 'iris', 'mono')"
           )
  end
end
