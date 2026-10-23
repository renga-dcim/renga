defmodule Renga.Repo.Migrations.CreateOrganizationDomains do
  use Ecto.Migration

  # RFD 15: an email domain an organization proves it controls with a DNS
  # TXT record, so the main sign-in page can send people with that domain
  # to the organization's identity provider. Several organizations may
  # claim a domain, but only one at a time may have it verified.
  def change do
    create table(:organization_domains, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :domain, :citext, null: false
      add :token, :string, null: false
      add :verified_at, :utc_datetime_usec
      add :checked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:organization_domains, [:organization_id, :domain])

    create unique_index(:organization_domains, [:domain],
             where: "verified_at IS NOT NULL",
             name: :organization_domains_one_verified_index
           )
  end
end
