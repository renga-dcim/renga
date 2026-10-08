defmodule Renga.Repo.Migrations.CreateSavedViews do
  @moduledoc """
  Saved views (RFD 8): a named filter, grouping, and column set for a list.

  A view with a `user_id` is personal to that member; one without is shared
  with the whole organization. `pinned` puts it in the sidebar. `params`
  holds the list's URL query, so opening a view is just visiting the list
  with those params.

  Existing organizations get the "Stale inventory" view that the sidebar
  used to hard-code, pinned, so their sidebar keeps it.
  """

  use Ecto.Migration

  def up do
    create table(:saved_views, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      # Owner of a personal view; NULL marks an organization view.
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id)
      add :created_by_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :area, :string, null: false
      add :name, :string, null: false
      add :params, :map, null: false, default: %{}
      add :pinned, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:saved_views, [:organization_id, :area])
    create index(:saved_views, [:organization_id, :user_id])

    # Names are unique among the views one person sees for a list: their own
    # personal views, and the organization's views.
    create unique_index(:saved_views, [:organization_id, :user_id, :area, "lower(name)"],
             where: "user_id IS NOT NULL",
             name: :saved_views_personal_name_index
           )

    create unique_index(:saved_views, [:organization_id, :area, "lower(name)"],
             where: "user_id IS NULL",
             name: :saved_views_organization_name_index
           )

    execute """
    INSERT INTO saved_views (id, organization_id, area, name, params, pinned, inserted_at, updated_at)
    SELECT gen_random_uuid(), organizations.id, 'inventory', 'Stale inventory',
           '{"freshness": "stale"}'::jsonb, true, now(), now()
    FROM organizations
    """
  end

  def down do
    drop table(:saved_views)
  end
end
