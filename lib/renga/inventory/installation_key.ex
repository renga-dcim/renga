defmodule Renga.Inventory.InstallationKey do
  @moduledoc """
  The Ed25519 public key an installation presents on check-in (RFD 13,
  "Installation credentials").

  An intake key proves only the organization, so the installation key is
  what tells one installation from another. A key is `pending` until an
  owner or admin approves it by comparing fingerprints, and `replaced` once
  the installation presents a different key. At most one key per
  installation is current, pending or approved.
  """

  use Ecto.Schema

  alias Renga.Inventory.Agent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  @algorithms ~w(ed25519)
  @statuses ~w(pending approved replaced)

  schema "installation_keys" do
    field :algorithm, :string
    field :public_key, :binary, redact: true
    field :fingerprint, :string
    field :status, :string, default: "pending"
    field :first_presented_at, :utc_datetime_usec
    field :last_presented_at, :utc_datetime_usec
    field :approved_at, :utc_datetime_usec
    field :replaced_at, :utc_datetime_usec

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :agent, Agent
    belongs_to :approved_by_user, Renga.Accounts.User

    timestamps()
  end

  def algorithms, do: @algorithms
  def statuses, do: @statuses

  @doc """
  The fingerprint people compare: SHA-256 of the raw public key, unpadded
  base64, as `renga-agent fingerprint` prints it.
  """
  def fingerprint(public_key) when byte_size(public_key) == 32,
    do: "SHA256:" <> Base.encode64(:crypto.hash(:sha256, public_key), padding: false)
end
