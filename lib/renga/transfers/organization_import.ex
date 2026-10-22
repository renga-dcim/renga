defmodule Renga.Transfers.OrganizationImport do
  @moduledoc """
  An archive imported into an organization (RFD 20): where it came from,
  what it held, and who imported it. Only an import that landed has a row;
  one that failed changed nothing.

  `held_settings` are source settings that would weaken the destination's
  security, kept here for an owner to confirm rather than applied.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {Renga.Time, :utc_now_ms, []},
    updated_at: false
  ]

  schema "organization_imports" do
    field :source_organization_id, :binary_id
    field :source_slug, :string
    field :source_name, :string
    field :format_version, :integer
    field :renga_version, :string
    field :snapshot_at, :utc_datetime_usec
    field :parts, {:array, :string}, default: []
    field :records, :integer
    field :sha256, :string
    field :source_settings, :map, default: %{}
    field :held_settings, :map, default: %{}
    field :operator, :string

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :imported_by_user, Renga.Accounts.User

    timestamps()
  end
end
