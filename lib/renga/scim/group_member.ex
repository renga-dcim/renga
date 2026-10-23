defmodule Renga.Scim.GroupMember do
  @moduledoc "A directory entry's membership in a directory group of the same connection."

  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  schema "scim_group_members" do
    field :connection_id, :binary_id

    belongs_to :group, Renga.Scim.DirectoryGroup, primary_key: true
    belongs_to :user, Renga.Scim.DirectoryUser, primary_key: true
  end
end
