defmodule Renga.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Renga.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use in authorization checks,
  or to ensure specific code paths can only be accessed for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.User

  defstruct user: nil,
            organization: nil,
            organization_id: nil,
            membership_id: nil,
            roles: []

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  Creates a scope for an organization.

  This is useful for source-authenticated API requests and system tasks that
  operate inside a tenant without a human user.
  """
  def new(%Organization{} = organization, attrs \\ %{}) when is_map(attrs) do
    %__MODULE__{
      user: Map.get(attrs, :user),
      organization: organization,
      organization_id: organization.id,
      membership_id: Map.get(attrs, :membership_id),
      roles: Map.get(attrs, :roles, [])
    }
  end

  @doc """
  Creates a scope for a user and organization membership.

  Web requests should prefer this shape after organization selection so context
  calls have both the human actor and the tenant boundary available.
  """
  def for_membership(
        %User{} = user,
        %Organization{} = organization,
        %OrganizationMembership{} = membership
      ) do
    %__MODULE__{
      user: user,
      organization: organization,
      organization_id: organization.id,
      membership_id: membership.id,
      roles: [membership.role]
    }
  end
end
