defmodule Renga.Scim.DirectoryUser do
  @moduledoc """
  A directory entry (RFD 16, "Directory entries"): a user a connection's
  provider has assigned to the organization. It is not a Renga account. Its
  `id` is the SCIM `id` Renga assigned; `user_identity_id`, when set, names
  the RFD 15 identity that proved its correlation claim, and the account is
  reached only through that identity.

  The SCIM `password` attribute has no field here: it is never kept.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @fields ~w(user_name external_id display_name formatted_name given_name family_name email active)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "scim_users" do
    field :user_name, :string
    field :external_id, :string
    field :display_name, :string
    field :formatted_name, :string
    field :given_name, :string
    field :family_name, :string
    field :email, :string
    field :active, :boolean, default: true
    field :organization_id, :binary_id

    belongs_to :connection, Renga.Scim.Connection
    belongs_to :user_identity, Renga.Accounts.UserIdentity

    many_to_many :groups, Renga.Scim.DirectoryGroup,
      join_through: Renga.Scim.GroupMember,
      join_keys: [user_id: :id, group_id: :id]

    timestamps(type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []})
  end

  @doc "The attributes a SCIM write sets."
  def fields, do: @fields

  @doc """
  A changeset for a SCIM write. `attrs` holds every field the write sets,
  already normalized. Changing or clearing `external_id` clears the identity
  binding, since the binding was proved against the old value.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required([:user_name, :active])
    # The columns are varchar(255), which counts code points, not graphemes.
    |> validate_length(:user_name, max: 255, count: :codepoints)
    |> validate_length(:external_id, max: 255, count: :codepoints)
    |> validate_length(:display_name, max: 255, count: :codepoints)
    |> validate_length(:formatted_name, max: 255, count: :codepoints)
    |> validate_length(:given_name, max: 255, count: :codepoints)
    |> validate_length(:family_name, max: 255, count: :codepoints)
    |> validate_length(:email, max: 255, count: :codepoints)
    |> unbind_on_external_id_change()
    |> unique_constraint(:user_name,
      name: :scim_users_connection_id_user_name_index,
      message: "is already taken"
    )
    |> unique_constraint(:external_id,
      name: :scim_users_connection_id_external_id_index,
      message: "is already taken"
    )
  end

  defp unbind_on_external_id_change(changeset) do
    if changed?(changeset, :external_id),
      do: put_change(changeset, :user_identity_id, nil),
      else: changeset
  end
end
