defmodule Renga.Accounts.OrganizationProviders do
  @moduledoc """
  An organization's own identity providers, managed by its owners (RFD 15,
  "Organization providers").

  Each function checks, in the transaction that makes the change, that the
  person is one of the organization's owners, then makes the change through
  `IdentityProviders`, so an
  organization's providers follow the same revision, test sign-in, and
  history rules as the deployment's. The provider is always looked up again
  within the scope's organization, so one organization can never name
  another's provider.

  An organization provider is always OpenID Connect over https, and every
  request Renga makes for it follows the operator's destination policy
  (`Renga.Accounts.OIDC.Destinations`).
  """

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.Scope
  alias Renga.Authorization
  alias Renga.Repo
  alias Renga.Scim.Grants

  @permission "organization.manage"

  @doc "Whether the scope may manage the organization's providers, for the UI."
  def manage?(%Scope{} = scope),
    do: Authorization.allowed?(scope, @permission) and "owner" in scope.roles

  @doc "The organization's providers."
  def list(%Scope{organization_id: organization_id}) when is_binary(organization_id),
    do: IdentityProviders.list_for_organization(organization_id)

  @doc "One of the organization's providers, or nil."
  def get(%Scope{organization_id: organization_id}, id)
      when is_binary(organization_id) and is_binary(id),
      do: IdentityProviders.get_for_organization(organization_id, id)

  @doc """
  A fresh provider ID. The new-provider form shows its callback URL, which
  the owner registers at their identity provider before they have a client
  ID to enter.
  """
  def new_id do
    suffix =
      :crypto.strong_rand_bytes(8)
      |> Base.encode32(case: :lower, padding: false)
      |> binary_part(0, 10)

    "org-" <> suffix
  end

  @doc "Adds a provider to the organization, pending a test sign-in."
  def create(%Scope{} = scope, attrs) do
    attrs = Map.put(attrs, "kind", "oidc")

    authorized(scope, nil, fn ->
      IdentityProviders.create(attrs, actor(scope), organization_id: scope.organization_id)
    end)
  end

  @doc "Changes the provider's display name or icon."
  def update_display(%Scope{} = scope, %IdentityProvider{} = provider, attrs),
    do: change(scope, provider, &IdentityProviders.update_display(&1, attrs, actor(scope)))

  @doc "Proposes new authentication settings, pending a test sign-in."
  def propose_revision(%Scope{} = scope, %IdentityProvider{} = provider, attrs),
    do: change(scope, provider, &IdentityProviders.propose_revision(&1, attrs, actor(scope)))

  @doc "Discards the proposed settings."
  def discard_pending(%Scope{} = scope, %IdentityProvider{} = provider),
    do: change(scope, provider, &IdentityProviders.discard_pending(&1, actor(scope)))

  @doc """
  Starts a test sign-in of the proposed settings. Returns
  `{:ok, {token, test}}`; `/users/providers/test/<token>` opens it once.
  """
  def create_test(%Scope{} = scope, %IdentityProvider{} = provider),
    do: change(scope, provider, &IdentityProviders.create_test(&1, actor(scope)))

  @doc "Turns sign-in through the provider on."
  def enable(%Scope{} = scope, %IdentityProvider{} = provider),
    do: change(scope, provider, &IdentityProviders.enable(&1, actor(scope)))

  @doc "Turns sign-in through the provider off."
  def disable(%Scope{} = scope, %IdentityProvider{} = provider),
    do: change(scope, provider, &IdentityProviders.disable(&1, actor(scope)))

  @doc "Sets whether the provider's authentication counts as MFA."
  def set_mfa_mark(%Scope{} = scope, %IdentityProvider{} = provider, attrs),
    do: change(scope, provider, &IdentityProviders.set_mfa_mark(&1, attrs, actor(scope)))

  @doc "Removes the provider; its ID is never reused."
  def remove(%Scope{} = scope, %IdentityProvider{} = provider),
    do: change(scope, provider, &IdentityProviders.remove(&1, actor(scope)))

  defp change(scope, %IdentityProvider{id: id}, fun) do
    scoped = %IdentityProvider{id: id, organization_id: scope.organization_id}

    authorized(scope, scoped, fn ->
      case get(scope, id) do
        %IdentityProvider{} = provider -> fun.(provider)
        nil -> {:error, :not_found}
      end
    end)
  end

  # The provider locks come before the organization's, as in every other
  # provider change and in SCIM's connection changes (RFD 16), and the SCIM
  # access changes a disable or removal makes are announced only once this,
  # the outermost transaction, commits.
  defp authorized(%Scope{organization_id: organization_id} = scope, provider, fun)
       when is_binary(organization_id) do
    Grants.announcing(fn ->
      IdentityProviders.locked(provider, fn ->
        authorize_owner!(scope)
        fun.()
      end)
    end)
  end

  defp authorized(_scope, _provider, _fun), do: {:error, :forbidden}

  @doc """
  Within a transaction, rolls it back with `:forbidden` unless `scope` is a
  current owner of its organization. A test sign-in of an organization's
  provider checks this again as it activates the revision.
  """
  def authorize_owner!(%Scope{} = scope) do
    Authorization.authorize!(scope, @permission, lock: :share)
    owner!(scope)
    :ok
  end

  # `organization.manage` can also come from a custom role, but it does not
  # cover identity providers (RFD 17); only the built-in owner role does,
  # held as the base role or a current assignment.
  defp owner!(scope) do
    if "owner" not in Authorization.current_roles!(scope), do: Repo.rollback(:forbidden)
  end

  defp actor(%Scope{user: user}), do: {:user, user}
end
