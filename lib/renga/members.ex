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
  alias Renga.Accounts.UserNotifier
  alias Renga.Authorization
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Changes
  alias Renga.Repo

  @doc "UI hint for `members.manage`."
  def can_manage?(%Scope{} = scope), do: Authorization.allowed?(scope, "members.manage")

  @doc """
  The roles the scope's cached role may grant, for pickers. The transaction
  re-reads the actor's role before relying on it.
  """
  def grantable_roles(%Scope{} = scope) do
    if can_manage?(scope),
      do: scope.roles |> Enum.flat_map(&Authorization.grantable_roles/1) |> Enum.uniq(),
      else: []
  end

  @doc "Every member of the organization, active and disabled, by email."
  def list_members(%Scope{organization_id: organization_id}) do
    OrganizationMembership
    |> join(:inner, [membership], user in assoc(membership, :user))
    |> where([membership], membership.organization_id == ^organization_id)
    |> order_by([membership, user], asc: membership.status, asc: user.email)
    |> preload([_membership, user], user: user)
    |> Repo.all()
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

        role not in actor_ceiling ->
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
        ceiling = scope |> actor_role() |> Authorization.grantable_roles()
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
      ceiling = scope |> actor_role() |> Authorization.grantable_roles()

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
  `:wrong_email`, `:already_member`, or `:forbidden`.
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
          "member" => recipient.email,
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

  defp confirmed_recipient(%User{confirmed_at: nil}, _invitation), do: {:error, :wrong_email}

  defp confirmed_recipient(%User{email: email}, %OrganizationInvitation{email: invited}) do
    if String.downcase(email) == String.downcase(invited), do: :ok, else: {:error, :wrong_email}
  end

  defp inviter_may_grant(%OrganizationInvitation{invited_by_user_id: nil}),
    do: {:error, :forbidden}

  defp inviter_may_grant(%OrganizationInvitation{} = invitation) do
    OrganizationMembership
    |> where([membership], membership.organization_id == ^invitation.organization_id)
    |> where([membership], membership.user_id == ^invitation.invited_by_user_id)
    |> where([membership], membership.status == "active")
    |> where([membership], membership.role in ^Authorization.roles_granting("members.manage"))
    |> select([membership], membership.role)
    |> lock("FOR SHARE")
    |> Repo.one()
    |> case do
      nil ->
        {:error, :forbidden}

      role ->
        if invitation.role in Authorization.grantable_roles(role),
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
  # bounded by the ceiling of the actor's current role, re-read here rather
  # than trusted from the scope: the target's current role must be within it.
  defp administer(%Scope{} = scope, membership_id, change) do
    Repo.transaction(fn ->
      Authorization.authorize!(scope, "members.manage")
      ceiling = scope |> actor_role() |> Authorization.grantable_roles()

      with {:ok, member} <- lock_member(scope, membership_id),
           true <- member.role in ceiling || {:error, :forbidden},
           {:ok, member} <- change.(ceiling, member) do
        Repo.preload(member, :user)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Changes.broadcast(scope.organization_id)
  end

  # authorize!/3 has already locked the actor's membership.
  defp actor_role(%Scope{membership_id: membership_id}) do
    OrganizationMembership
    |> where([membership], membership.id == ^membership_id)
    |> select([membership], membership.role)
    |> Repo.one!()
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
  # change, so counting the other active owners here cannot race.
  defp last_active_owner?(%OrganizationMembership{role: "owner", status: "active"} = member) do
    not (OrganizationMembership
         |> where([membership], membership.organization_id == ^member.organization_id)
         |> where([membership], membership.id != ^member.id)
         |> where([membership], membership.role == "owner" and membership.status == "active")
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
