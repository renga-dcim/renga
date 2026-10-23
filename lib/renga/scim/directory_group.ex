defmodule Renga.Scim.DirectoryGroup do
  @moduledoc """
  A group a connection's provider pushes (RFD 16, "Directory entries"). Its
  `id` is the Renga-assigned SCIM id that role mappings name, so a rename
  keeps a group's mapping and a recreated group starts without one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "scim_groups" do
    field :display_name, :string
    field :external_id, :string
    field :organization_id, :binary_id

    belongs_to :connection, Renga.Scim.Connection

    many_to_many :members, Renga.Scim.DirectoryUser,
      join_through: Renga.Scim.GroupMember,
      join_keys: [group_id: :id, user_id: :id]

    timestamps(type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []})
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:display_name, :external_id], empty_values: [])
    |> validate_required([:display_name])
    # The columns are varchar(255), which counts code points, not graphemes.
    |> validate_length(:display_name, max: 255, count: :codepoints)
    |> validate_length(:external_id, max: 255, count: :codepoints)
    |> unique_constraint(:display_name,
      name: :scim_groups_connection_id_display_name_index,
      message: "is already taken"
    )
  end
end
