defmodule Renga.Operators.Organizations do
  @moduledoc """
  What an operator does to organizations through the operator API (RFD 22,
  "Organizations"): create one with no members, read it with its members,
  and invite an owner by email.

  Every mutation runs through `Renga.DeploymentAudit.mutate/3`, so it is
  recorded in the deployment audit log, and is also recorded in the
  organization's Activity under the operator's name. Writes take an
  optional `Renga.Operators.Idempotency`, which the API passes and release
  commands leave out.

  An owner invitation is an ordinary organization invitation for the
  `owner` role. The operator never receives its secret or a sign-in link:
  Renga emails the link to the invited address, and accepting it requires
  signing in, or registering, with that confirmed address under the
  deployment's own sign-in rules. It stays valid only while the token that
  made it is unrevoked, as a person's invitations stay valid only while
  they may still grant the role.
  """

  import Ecto.Query

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationInvitation
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.UserNotifier
  alias Renga.DeploymentAudit
  alias Renga.Inventory.ChangeEvent
  alias Renga.Operators.Idempotency
  alias Renga.Operators.OperatorToken
  alias Renga.Repo

  @doc """
  Creates an organization from `attrs` (`name` and `slug`) with no members.
  Returns `{:ok, organization}`, `{:error, changeset}`, or
  `{:error, :replayed}` when a concurrent retry finished first.
  """
  def create(attrs, context, idempotency \\ nil) when is_map(attrs) do
    DeploymentAudit.mutate(context, "organization.create", fn ->
      with :ok <- Idempotency.begin(idempotency),
           {:ok, organization} <-
             %Organization{}
             |> Organization.changeset(Map.take(attrs, ["name", "slug"]))
             |> Repo.insert() do
        record_activity!(organization, "organization_created", context, %{})
        :ok = Idempotency.finish!(idempotency, organization)

        {:ok, organization,
         %{organization: organization, target_id: organization.id, changed: [:name, :slug]}}
      else
        {:error, reason} -> {:error, reason, %{}}
      end
    end)
  end

  @doc """
  Gets an organization with its active members' addresses and roles, or
  `nil`.
  """
  def get(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Organization{} = organization <- Repo.get(Organization, id) do
      members =
        OrganizationMembership
        |> join(:inner, [membership], user in assoc(membership, :user))
        |> where([membership], membership.organization_id == ^organization.id)
        |> where([membership], membership.status == "active")
        |> order_by([_membership, user], asc: user.email)
        |> select([membership, user], %{email: user.email, role: membership.role})
        |> Repo.all()

      %{organization: organization, members: members}
    else
      _missing -> nil
    end
  end

  @doc """
  Invites `email` to own the organization `organization_id` and emails them
  a link built by `url_fun` from the invitation's secret. Inviting an
  address again replaces its open invitation.

  Returns `{:ok, invitation}`, `{:error, :not_found}` for an unknown or
  disabled organization, `{:error, changeset}` for an invalid address or
  one that already belongs to a member, `{:error, :delivery_failed}` when the
  email could not be sent, or `{:error, :replayed}`.
  """
  def invite_owner(organization_id, email, context, url_fun, idempotency \\ nil)
      when is_function(url_fun, 1) do
    {token, token_hash} = OrganizationInvitation.build_token()

    result =
      DeploymentAudit.mutate(context, "organization.invite_owner", fn ->
        with :ok <- Idempotency.begin(idempotency),
             {:ok, organization} <- lock_active(organization_id),
             {:ok, invitation} <- insert_invitation(organization, email, token_hash, context) do
          invitation = %{invitation | organization: organization}

          case deliver_invitation(invitation, token, url_fun) do
            :ok ->
              :ok = Idempotency.finish!(idempotency, invitation)

              {:ok, invitation,
               %{
                 organization: organization,
                 target_id: invitation.id,
                 changed: [:invitation]
               }}

            {:error, :delivery_failed} ->
              {:error, :delivery_failed,
               %{organization: organization, target_id: invitation.id}}
          end
        else
          {:error, :not_found} ->
            {:error, :not_found, %{target_id: organization_id}}

          {:error, %Ecto.Changeset{} = changeset, organization} ->
            {:error, changeset, %{organization: organization}}

          {:error, reason} ->
            {:error, reason, %{}}
        end
      end)

    result
  end

  defp deliver_invitation(invitation, token, url_fun) do
    case UserNotifier.deliver_organization_invitation(
           invitation.email,
           invitation.organization.name,
           invitation.role,
           url_fun.(token)
         ) do
      {:ok, _email} -> :ok
      {:error, _reason} -> {:error, :delivery_failed}
    end
  end

  defp lock_active(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Organization{status: "active"} = organization <-
           Organization |> where([o], o.id == ^id) |> lock("FOR UPDATE") |> Repo.one() do
      {:ok, organization}
    else
      _missing_or_disabled -> {:error, :not_found}
    end
  end

  defp insert_invitation(organization, email, token_hash, %{actor: actor} = context) do
    now = Renga.Time.utc_now_ms()

    changeset =
      %OrganizationInvitation{
        organization_id: organization.id,
        invited_by_operator: DeploymentAudit.actor_label(context),
        invited_by_operator_token_id: token_id(actor),
        token_hash: token_hash,
        expires_at: DateTime.add(now, OrganizationInvitation.validity_days(), :day)
      }
      |> OrganizationInvitation.create_changeset(%{email: email, role: "owner"})
      |> Ecto.Changeset.validate_change(:email, fn :email, email ->
        if member_email?(organization, email),
          do: [email: "already belongs to a member"],
          else: []
      end)

    with true <- changeset.valid? || {:error, changeset, organization},
         :ok <- replace_open_invitation(organization, changeset.changes.email, now, context),
         {:ok, invitation} <- Repo.insert(changeset) do
      record_activity!(organization, "member_invited", context, %{
        new_value: %{"value" => invitation.role},
        metadata: %{"member" => invitation.email, "invitation_id" => invitation.id}
      })

      {:ok, invitation}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset, organization}
      error -> error
    end
  end

  defp member_email?(organization, email) do
    OrganizationMembership
    |> join(:inner, [membership], user in assoc(membership, :user))
    |> where([membership], membership.organization_id == ^organization.id)
    |> where([_membership, user], user.email == ^email)
    |> Repo.exists?()
  end

  # Any open invitation for the address is replaced, whoever made it: the
  # operator may always invite an owner, the most it could grant.
  defp replace_open_invitation(organization, email, now, context) do
    OrganizationInvitation
    |> where([invitation], invitation.organization_id == ^organization.id)
    |> where([invitation], invitation.email == ^email)
    |> where([invitation], is_nil(invitation.accepted_at) and is_nil(invitation.revoked_at))
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Enum.each(fn invitation ->
      invitation |> Ecto.Changeset.change(revoked_at: now) |> Repo.update!()

      record_activity!(organization, "invitation_revoked", context, %{
        old_value: %{"value" => invitation.role},
        metadata: %{
          "member" => invitation.email,
          "invitation_id" => invitation.id,
          "reason" => "Replaced by a new invitation"
        }
      })
    end)

    :ok
  end

  defp token_id({:token, %OperatorToken{id: id}}), do: id
  defp token_id({:operator, _name}), do: nil

  # No person in the organization made the change, so the entry names the
  # operator, as limit changes do.
  defp record_activity!(organization, kind, context, attrs) do
    metadata =
      attrs
      |> Map.get(:metadata, %{})
      |> Map.put("operator", DeploymentAudit.actor_label(context))
      |> put_operator_token_id(context.actor)

    %ChangeEvent{organization_id: organization.id}
    |> ChangeEvent.changeset(
      attrs
      |> Map.put(:kind, kind)
      |> Map.put(:metadata, metadata)
      |> Map.put(:occurred_at, Renga.Time.utc_now_ms())
    )
    |> Repo.insert!()
  end

  defp put_operator_token_id(metadata, {:token, %OperatorToken{id: id}}),
    do: Map.put(metadata, "operator_token_id", id)

  defp put_operator_token_id(metadata, {:operator, _name}), do: metadata
end
