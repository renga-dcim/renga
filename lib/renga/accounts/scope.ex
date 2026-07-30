defmodule Renga.Accounts.Scope do
  @moduledoc """
  Request and context scope for organization-scoped operations.
  """

  alias Renga.Accounts.Organization

  @enforce_keys [:organization_id]
  defstruct [:organization, :organization_id, :user_id, :membership_id, roles: []]

  def new(%Organization{} = organization, attrs \\ %{}) when is_map(attrs) do
    %__MODULE__{
      organization: organization,
      organization_id: organization.id,
      user_id: Map.get(attrs, :user_id),
      membership_id: Map.get(attrs, :membership_id),
      roles: Map.get(attrs, :roles, [])
    }
  end
end
