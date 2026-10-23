defmodule Renga.Members do
  @moduledoc """
  An organization's members and their base roles (RFD 17, "Administration").

  Holders of `members.manage` change a member's base role and disable or
  re-enable them. What they may change is bounded by the grant ceiling of
  their own built-in role (`Renga.Authorization.grantable_roles/1`): an admin
  manages admins, members, and viewers, and only an owner manages owners.

  New people join through invitations: an expiring, revocable, single-use
  link bound to one email address and one role, which only a signed-in
  account that has confirmed that address can accept.

  An organization always keeps at least one active owner, its recovery
  owner, so no change may disable or demote the last one. Every change is
  an Activity entry with its actor, the before and after values, and the
  reason given. Authorization-changing writes take the organization lock
  first, like every other protected mutation, so they serialize with the
  decisions they affect.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.OrganizationInvitation
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.Accounts.User
  alias Renga.Accounts.UserIdentity
  alias Renga.Accounts.UserNotifier
  alias Renga.Authorization
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Changes
  alias Renga.Operators.OperatorToken
  alias Renga.Repo

  @doc "UI hint for `members.manage`."
  def can_manage?(%Scope{} = scope), do: Authorization.allowed?(scope, "members.manage")

  @doc """
  The roles the scope's cached roles may grant, for pickers. The transaction
  re-reads the actor's roles before relying on them.
  """
  def grantable_roles(%Scope{} = scope) do
    if can_manage?(scope), do: Authorization.grantable_roles(scope.roles), else: []
  end

  @doc """
  Every member of the organization, active and disabled, by email. A member
  without a global email carries the address the organization's own
  provider asserts for them as `user.organization_email` (RFD 15).
  """
  def list_members(%Scope{organization_id: organization_id}) do
    OrganizationMembership
    |> join(:inner, [membership], user in assoc(membership, :user))
    |> where([membership], membership.organization_id == ^organization_id)
    |> order_by([membership, user], asc: membership.status, asc: user.email)
    |> preload([_membership, user], user: user)
    |> Repo.all()
    |> put_organization_emails(organization_id)
  end

  defp put_organization_emails(members, organization_id) do
    user_ids = for %{user: %User{email: nil, id: id}} <- members, do: id
    emails = organization_emails(organization_id, user_ids)

    Enum.map(members, fn member ->
      %{member | user: %{member.user | organization_email: emails[member.user_id]}}
    end)
  end

  defp organization_emails(_organization_id, []), do: %{}

  defp organization_emails(organization_id, user_ids) do
    UserIdentity
    |> join(:inner, [identity], provider in assoc(identity, :provider))
    |> where([identity], identity.user_id in ^user_ids and not is_nil(identity.email))
    |> where([_identity, provider], provider.organization_id == ^organization_id)
    |> order_by([identity], asc: identity.last_signed_in_at)
    |> select([identity], {identity.user_id, identity.email})
    |> Repo.all()
    # The most recent sign-in's address wins.
    |> Map.new()
  end

  @doc """
  Changes a member's base role. `opts` may carry a `:reason` for Activity.

  Returns `{:error, :forbidden}` when the actor lacks `members.manage` or
  either role is above their grant ceiling, and `{:error, :last_owner}` when
  it would demote the organization's last active owner.
  """
  def change_role(%Scope{} = scope, membership_id, role, opts \\ []) do
    administer(scope, membership_id, fn actor_ceiling, member ->
      cond do
        role not in Authorization.built_in_roles() ->
          {:error, :invalid_role}

        member.role == role ->
          {:ok, member}

        role not in actor_ceiling.roles ->
          {:error, :forbidden}

        last_active_owner?(member) ->
          {:error, :last_owner}

        true ->
          update!(scope, member, :role, role, "member_role_changed", opts)
      end
    end)
  end

  @doc """
  Disables a member: they can no longer open the organization, and their
  role grants nothing. Their membership and history stay. People cannot
  disable themselves.
  """
  def disable_member(%Scope{} = scope, membership_id, opts \\ []) do
    administer(scope, membership_id, fn _actor_ceiling, member ->
      cond do
        member.status == "disabled" -> {:ok, member}
        member.id == scope.membership_id -> {:error, :self}
        last_active_owner?(member) -> {:error, :last_owner}
        true -> update!(scope, member, :status, "disabled", "member_disabled", opts)
      end
    end)
  end

  @doc "Re-enables a disabled member with the base role they had."
  def enable_member(%Scope{} = scope, membership_id, opts \\ []) do
    administer(scope, membership_id, fn _actor_ceiling, member ->
      if member.status == "active",
        do: {:ok, member},
        else: update!(scope, member, :status, "active", "member_enabled", opts)
    end)
  end

  ## Invitations

  @doc "Open invitations, newest first. Expired ones stay until replaced or revoked."
  def list_invitations(%Scope{organization_id: organization_id}) do
    OrganizationInvitation
    |> where([invitation], invitation.organization_id == ^organization_id)
    |> where([invitation], is_nil(invitation.accepted_at) and is_nil(invitation.revoked_at))
    |> order_by([invitation], desc: invitation.inserted_at)
    |> preload(:invited_by_user)
    |> Repo.all()
  end

  def change_invitation(attrs \\ %{}),
    do: OrganizationInvitation.create_changeset(%OrganizationInvitation{}, attrs)

  @doc """
  Invites `attrs["email"]` with `attrs["role"]`, which must be within the
  actor's grant ceiling, and emails them a link built by `url_fun` from the
  token. Inviting an address again replaces its open invitation. Returns
  `{:error, changeset}` for an invalid address or role, or an address that
  already belongs to a member.
  """
  def invite(%Scope{} = scope, attrs, url_fun) when is_function(url_fun, 1) do
    {token, token_hash} = OrganizationInvitation.build_token()

    result =
      Repo.transaction(fn ->
        Authorization.authorize!(scope, "members.manage")
        ceiling = scope |> Authorization.current_roles!() |> Authorization.grantable_roles()
        now = Renga.Time.utc_now_ms()

        changeset =
          %OrganizationInvitation{
            organization_id: scope.organization_id,
            invited_by_user_id: scope.user.id,
            token_hash: token_hash,
            expires_at: DateTime.add(now, OrganizationInvitation.validity_days(), :day)
          }
          |> OrganizationInvitation.create_changeset(attrs)
          |> validate_invitable(scope, ceiling)

        with true <- changeset.valid? || {:error, changeset},
             :ok <- replace_open_invitation(scope, changeset.changes.email, ceiling, now),
             {:ok, invitation} <- Repo.insert(changeset) do
          record!(scope, "member_invited", nil, invitation.role, %{
            "member" => invitation.email,
            "invitation_id" => invitation.id
          })

          invitation
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    result = Changes.broadcast(result, scope.organization_id)

    with {:ok, invitation} <- result do
      organization = Repo.get!(Renga.Accounts.Organization, invitation.organization_id)

      case UserNotifier.deliver_organization_invitation(
             invitation.email,
             organization.name,
             invitation.role,
             url_fun.(token)
           ) do
        {:ok, _email} -> {:ok, invitation}
        {:error, _reason} -> {:error, {:delivery_failed, invitation}}
      end
    end
  end

  defp validate_invitable(changeset, scope, ceiling) do
    changeset
    |> Ecto.Changeset.validate_inclusion(:role, ceiling, message: "is above what you may grant")
    |> Ecto.Changeset.validate_change(:email, fn :email, email ->
      if member_email?(scope, email), do: [email: "already belongs to a member"], else: []
    end)
  end

  defp member_email?(%Scope{organization_id: organization_id}, email) do
    OrganizationMembership
    |> join(:inner, [membership], user in assoc(membership, :user))
    |> where([membership], membership.organization_id == ^organization_id)
    |> where([_membership, user], user.email == ^email)
    |> Repo.exists?()
  end

  defp replace_open_invitation(scope, email, ceiling, now) do
    invitation =
      OrganizationInvitation
      |> where([invitation], invitation.organization_id == ^scope.organization_id)
      |> where([invitation], invitation.email == ^email)
      |> where([invitation], is_nil(invitation.accepted_at) and is_nil(invitation.revoked_at))
      |> lock("FOR UPDATE")
      |> Repo.one()

    case invitation do
      nil ->
        :ok

      %OrganizationInvitation{} = invitation ->
        if invitation.role in ceiling do
          invitation
          |> Ecto.Changeset.change(revoked_at: now, revoked_by_user_id: scope.user.id)
          |> Repo.update!()

          record!(scope, "invitation_revoked", invitation.role, nil, %{
            "member" => invitation.email,
            "invitation_id" => invitation.id,
            "reason" => "Replaced by a new invitation"
          })

          :ok
        else
          {:error, :forbidden}
        end
    end
  end

  @doc "Revokes an open invitation whose role is within the actor's ceiling."
  def revoke_invitation(%Scope{} = scope, invitation_id) do
    Repo.transaction(fn ->
      Authorization.authorize!(scope, "members.manage")
      ceiling = scope |> Authorization.current_roles!() |> Authorization.grantable_roles()

      with {:ok, id} <- Ecto.UUID.cast(invitation_id),
           %OrganizationInvitation{accepted_at: nil, revoked_at: nil} = invitation <-
             OrganizationInvitation
             |> where([invitation], invitation.organization_id == ^scope.organization_id)
             |> where([invitation], invitation.id == ^id)
             |> lock("FOR UPDATE")
             |> Repo.one(),
           true <- invitation.role in ceiling || {:error, :forbidden} do
        invitation =
          invitation
          |> Ecto.Changeset.change(
            revoked_at: Renga.Time.utc_now_ms(),
            revoked_by_user_id: scope.user.id
          )
          |> Repo.update!()

        record!(scope, "invitation_revoked", invitation.role, nil, %{
          "member" => invitation.email,
          "invitation_id" => invitation.id
        })

        invitation
      else
        {:error, :forbidden} -> Repo.rollback(:forbidden)
        _missing_or_closed -> Repo.rollback(:not_found)
      end
    end)
    |> Changes.broadcast(scope.organization_id)
  end

  @doc "The open invitation for `token`, with its organization, or nil."
  def get_open_invitation(token) when is_binary(token) do
    now = Renga.Time.utc_now_ms()

    OrganizationInvitation
    |> where([invitation], invitation.token_hash == ^OrganizationInvitation.hash_token(token))
    |> preload(:organization)
    |> Repo.one()
    |> case do
      %OrganizationInvitation{organization: %{status: "active"}} = invitation ->
        if OrganizationInvitation.open?(invitation, now), do: invitation

      _missing_or_inactive ->
        nil
    end
  end

  @doc """
  Accepts the invitation for `token` as `user`, creating their membership.

  The user must have confirmed the invited address, and the person who
  invited them must still hold `members.manage` with a ceiling covering the
  role, so revoking an admin also stops what they invited. Returns
  `{:error, reason}` with `:invalid` (unknown, used, revoked, or expired),
  `:wrong_email`, `:already_member`, `:forbidden`, or `:scoped_session` when
  the user's session is scoped to another organization (RFD 15).
  """
  def accept_invitation(%User{} = user, token) when is_binary(token) do
    token_hash = OrganizationInvitation.hash_token(token)

    Repo.transaction(fn ->
      organization_id =
        OrganizationInvitation
        |> where([invitation], invitation.token_hash == ^token_hash)
        |> select([invitation], invitation.organization_id)
        |> Repo.one()

      with organization_id when is_binary(organization_id) <- organization_id,
           :ok <- session_may_join(user, organization_id),
           :ok <- Authorization.lock_active_organization!(organization_id),
           %OrganizationInvitation{} = invitation <- lock_invitation(organization_id, token_hash),
           %User{} = recipient <- lock_recipient(user.id),
           now = Renga.Time.utc_now_ms(),
           true <- OrganizationInvitation.open?(invitation, now),
           :ok <- confirmed_recipient(recipient, invitation),
           :ok <- inviter_may_grant(invitation),
           :ok <- not_yet_member(recipient, invitation) do
        {:ok, membership} =
          %OrganizationMembership{organization_id: invitation.organization_id}
          |> OrganizationMembership.changeset(%{user_id: recipient.id, role: invitation.role})
          |> Repo.insert()

        invitation
        |> Ecto.Changeset.change(accepted_at: now, accepted_by_user_id: recipient.id)
        |> Repo.update!()

        scope = %Scope{user: recipient, organization_id: invitation.organization_id}

        record!(scope, "member_joined", nil, invitation.role, %{
          "member" => recipient.email || invitation.email,
          "membership_id" => membership.id,
          "invitation_id" => invitation.id
        })

        Repo.preload(membership, :organization)
      else
        {:error, reason} -> Repo.rollback(reason)
        _missing_or_closed -> Repo.rollback(:invalid)
      end
    end)
    |> then(fn
      {:ok, membership} = result -> Changes.broadcast(result, membership.organization_id)
      error -> error
    end)
  end

  # A session from an organization provider's sign-in can join only that
  # organization (RFD 15).
  defp session_may_join(%User{session_organization_id: nil}, _organization_id), do: :ok
  defp session_may_join(%User{session_organization_id: id}, id), do: :ok
  defp session_may_join(%User{}, _organization_id), do: {:error, :scoped_session}

  defp lock_invitation(organization_id, token_hash) do
    OrganizationInvitation
    |> where([invitation], invitation.organization_id == ^organization_id)
    |> where([invitation], invitation.token_hash == ^token_hash)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_recipient(user_id) do
    User
    |> where([user], user.id == ^user_id)
    |> lock("FOR SHARE")
    |> Repo.one()
  end

  # The invited address must be the account's confirmed global email, or
  # one that the inviting organization's own identity provider verified for
  # the account (RFD 15): that provider is trusted for its own organization,
  # so an account it created without a global email can join it.
  defp confirmed_recipient(%User{} = user, %OrganizationInvitation{} = invitation) do
    if confirmed_email?(user, invitation.email) or
         organization_verified_email?(user, invitation),
       do: :ok,
       else: {:error, :wrong_email}
  end

  defp confirmed_email?(%User{confirmed_at: nil}, _invited), do: false
  defp confirmed_email?(%User{email: nil}, _invited), do: false

  defp confirmed_email?(%User{email: email}, invited),
    do: String.downcase(email) == String.downcase(invited)

  defp organization_verified_email?(%User{id: user_id}, %OrganizationInvitation{} = invitation) do
    UserIdentity
    |> join(:inner, [identity], provider in assoc(identity, :provider))
    |> where([identity], identity.user_id == ^user_id and identity.email_verified)
    |> where(
      [identity],
      fragment("lower(?)", identity.email) == ^String.downcase(invitation.email)
    )
    |> where([_identity, provider], provider.organization_id == ^invitation.organization_id)
    |> where([_identity, provider], is_nil(provider.removed_at))
    |> Repo.exists?()
  end

  # An operator's owner invitation (RFD 22) stays valid while the token that
  # made it is unrevoked; one made by a release command has no token.
  defp inviter_may_grant(%OrganizationInvitation{
         invited_by_user_id: nil,
         invited_by_operator: operator,
         invited_by_operator_token_id: token_id
       })
       when is_binary(operator) do
    cond do
      is_nil(token_id) ->
        :ok

      OperatorToken
      |> where([token], token.id == ^token_id and is_nil(token.revoked_at))
      |> lock("FOR SHARE")
      |> Repo.exists?() ->
        :ok

      true ->
        {:error, :forbidden}
    end
  end

  defp inviter_may_grant(%OrganizationInvitation{invited_by_user_id: nil}),
    do: {:error, :forbidden}

  defp inviter_may_grant(%OrganizationInvitation{} = invitation) do
    OrganizationMembership
    |> where([membership], membership.organization_id == ^invitation.organization_id)
    |> where([membership], membership.user_id == ^invitation.invited_by_user_id)
    |> where([membership], membership.status == "active")
    |> Authorization.holding("members.manage")
    |> select([membership], membership.id)
    |> lock("FOR SHARE")
    |> Repo.one()
    |> case do
      nil ->
        {:error, :forbidden}

      inviter_membership_id ->
        ceiling =
          inviter_membership_id
          |> Authorization.current_roles!()
          |> Authorization.grantable_roles()

        if invitation.role in ceiling,
          do: :ok,
          else: {:error, :forbidden}
    end
  end

  defp not_yet_member(%User{id: user_id}, %OrganizationInvitation{
         organization_id: organization_id
       }) do
    OrganizationMembership
    |> where([membership], membership.organization_id == ^organization_id)
    |> where([membership], membership.user_id == ^user_id)
    |> Repo.exists?()
    |> if(do: {:error, :already_member}, else: :ok)
  end

  # Checks members.manage and locks the target. Administering a member is
  # bounded by the ceiling of the actor's current roles, re-read here rather
  # than trusted from the scope. The target's base role and every current
  # assignment must fit, because disabling or enabling takes away or restores
  # all of that access at once.
  defp administer(%Scope{} = scope, membership_id, change) do
    Repo.transaction(fn ->
      Authorization.authorize!(scope, "members.manage")
      roles = Authorization.current_roles!(scope)

      ceiling = %{
        roles: Authorization.grantable_roles(roles),
        permissions: Authorization.grantable_permissions(roles)
      }

      with {:ok, member} <- lock_member(scope, membership_id),
           :ok <- not_scim_managed(member),
           :ok <- member_within_ceiling(member, ceiling),
           {:ok, member} <- change.(ceiling, member) do
        Repo.preload(member, :user)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Changes.broadcast(scope.organization_id)
  end

  # The organization's identity provider decides a SCIM grant (RFD 16);
  # assignments still add to it.
  defp not_scim_managed(member) do
    if OrganizationMembership.scim_managed?(member), do: {:error, :scim_managed}, else: :ok
  end

  defp member_within_ceiling(member, ceiling) do
    now = Renga.Time.utc_now_ms()

    assignments =
      Renga.Roles.Assignment
      |> where([assignment], assignment.membership_id == ^member.id)
      |> where([assignment], is_nil(assignment.valid_until) or assignment.valid_until > ^now)
      |> preload(:role)
      |> Repo.all()

    allowed? =
      member.role in ceiling.roles and
        Enum.all?(assignments, fn
          %{built_in_role: role} when is_binary(role) -> role in ceiling.roles
          %{role: %{permissions: permissions}} -> permissions -- ceiling.permissions == []
        end)

    if allowed?, do: :ok, else: {:error, :forbidden}
  end

  defp lock_member(%Scope{organization_id: organization_id}, membership_id) do
    with {:ok, id} <- Ecto.UUID.cast(membership_id),
         %OrganizationMembership{} = member <-
           OrganizationMembership
           |> where([membership], membership.organization_id == ^organization_id)
           |> where([membership], membership.id == ^id)
           |> lock("FOR UPDATE")
           |> Repo.one() do
      {:ok, member}
    else
      _missing -> {:error, :not_found}
    end
  end

  # The organization lock taken by authorize!/3 serializes every membership
  # change, so counting the other active owners here cannot race. Only an
  # owner granted by hand counts: SCIM may remove its owners at any time.
  defp last_active_owner?(%OrganizationMembership{role: "owner", status: "active"} = member) do
    not (OrganizationMembership
         |> where([membership], membership.organization_id == ^member.organization_id)
         |> where([membership], membership.id != ^member.id)
         |> where([membership], membership.role == "owner" and membership.status == "active")
         |> where([membership], is_nil(membership.scim_connection_id))
         |> Repo.exists?())
  end

  defp last_active_owner?(%OrganizationMembership{}), do: false

  defp update!(scope, member, field, value, kind, opts) do
    old = Map.fetch!(member, field)

    member =
      member
      |> Ecto.Changeset.change(%{field => value})
      |> Repo.update!()

    member = Repo.preload(member, :user)

    record!(
      scope,
      kind,
      old,
      value,
      activity_metadata(member, opts[:reason]),
      Atom.to_string(field)
    )

    {:ok, member}
  end

  defp record!(scope, kind, old, new, metadata, field \\ "role") do
    %ChangeEvent{organization_id: scope.organization_id, actor_user_id: scope.user.id}
    |> ChangeEvent.changeset(%{
      kind: kind,
      field: field,
      old_value: old && %{"value" => old},
      new_value: new && %{"value" => new},
      metadata: metadata,
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()
  end

  defp activity_metadata(member, reason) do
    %{"membership_id" => member.id, "member" => member.user.email}
    |> then(&if(present?(reason), do: Map.put(&1, "reason", String.trim(reason)), else: &1))
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
