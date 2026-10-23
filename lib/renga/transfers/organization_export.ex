defmodule Renga.Transfers.OrganizationExport do
  @moduledoc """
  One export of an organization (RFD 20) and the state of its archive.

  An export is `running` until its archive is stored, then `ready` until it
  expires seven days later or an owner revokes it. A `failed` export never
  produced an archive. Only a `ready`, unexpired export can be downloaded,
  and its archive's chunks are deleted as soon as it leaves `ready`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @statuses ~w(running ready failed revoked expired)

  schema "organization_exports" do
    field :parts, {:array, :string}, default: []
    field :readable_payloads, {:array, :string}, default: []
    field :status, :string
    field :snapshot_at, :utc_datetime_usec
    field :records, :integer
    field :bytes, :integer
    field :sha256, :string
    field :finished_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :requested_by_user, Renga.Accounts.User
    belongs_to :revoked_by_user, Renga.Accounts.User

    timestamps()
  end

  def statuses, do: @statuses

  @doc "Whether the archive can be downloaded at `now`."
  def downloadable?(%__MODULE__{status: "ready", expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  def downloadable?(%__MODULE__{}, _now), do: false
end
