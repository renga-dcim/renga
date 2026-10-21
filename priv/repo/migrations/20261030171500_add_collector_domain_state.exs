defmodule Renga.Repo.Migrations.AddCollectorDomainState do
  use Ecto.Migration

  # RFD 11, "Virtualization collection": what a hypervisor last said about a
  # domain it defines. A domain that occupies the hypervisor has
  # `active_since`; an inactive definition has none.
  def change do
    alter table(:collector_target_resources) do
      add :domain, :map
      add :domain_reported_at, :"timestamp(3)"
      add :active_since, :"timestamp(3)"
    end

    create index(:collector_target_resources, [:organization_id, :resource_id],
             where: "active_since IS NOT NULL",
             name: :collector_target_resources_active_index
           )
  end
end
