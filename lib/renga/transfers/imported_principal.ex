defmodule Renga.Transfers.ImportedPrincipal do
  @moduledoc """
  A person an imported archive named (RFD 20). It records who the source
  says acted and is no account here until someone who controls its email
  address accepts an invitation for it, which links it to their account.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "imported_principals" do
    field :source_id, :binary_id
    field :email, :string
    field :linked_at, :utc_datetime_usec

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :organization_import, Renga.Transfers.OrganizationImport
    belongs_to :user, Renga.Accounts.User

    timestamps()
  end
end
