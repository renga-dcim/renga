defmodule Renga.Transfers.Principals do
  @moduledoc """
  Brings the people an imported archive named back into the organization
  (RFD 20, "Members").

  An import turns every person into an `ImportedPrincipal` and holds their
  memberships, team memberships, role assignments, and private saved views.
  Only a principal whose held membership is active can return, and only
  through an invitation to its email address, so accepting proves control
  of that address before anything applies. Accepting links the principal to
  the accepting account and, in the same transaction:

    * restores the membership, with its held ID and the invitation's role;
    * restores its team memberships, and its manual role assignments that
      are still valid and within what the inviter may grant;
    * restores its private saved views as the account's own;
    * fills the person fields of current records the principal was
      attributed with.

  What does not apply stays held. History keeps its imported attribution:
  Activity, job events, and cable claims never claim the account acted.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.OrganizationInvitation
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.Accounts.User
  alias Renga.Authorization
  alias Renga.Members
  alias Renga.Repo
  alias Renga.Roles.Assignment
  alias Renga.Roles.Role
  alias Renga.SavedViews.SavedView
  alias Renga.Teams.Team
  alias Renga.Teams.TeamMembership
  alias Renga.Transfers.ImportedPrincipal
  alias Renga.Transfers.RecordTypes

  # Held records, and cable claims, whose rows refuse updates: neither is
  # filled from an attribution. A cable claim names its principal instead.
  @not_filled [
    {"organization_memberships", "user_id"},
    {"saved_views", "user_id"},
    {"role_assignments", "created_by_user_id"},
    {"team_memberships", "added_by_user_id"},
    {"cable_assertions", "actor_user_id"}
  ]

  @doc """
  The organization's unlinked principals, by email, each with the role its
  held membership would return with, or nil when it cannot return: it was
  no active member, or the archive had no email for it.
  """
  def list_unlinked(%Scope{organization_id: organization_id}) do
    principals =
      ImportedPrincipal
      |> where([principal], principal.organization_id == ^organization_id)
      |> where([principal], is_nil(principal.user_id))
      |> order_by([principal], asc_nulls_last: principal.email)
      |> Repo.all()

    memberships = held_memberships(organization_id, Enum.map(principals, & &1.id))

    Enum.map(principals, fn principal ->
      %{principal: principal, role: returning_role(principal, memberships[principal.id])}
    end)
  end

  @doc """
  Invites an unlinked principal back with its held membership's role, like
  `Renga.Members.invite/3`. Returns `{:error, :not_found}` for a principal
  that is linked or not in the organization, `{:error, :not_eligible}` for
  one that cannot return, and `Renga.Members.invite/4`'s errors otherwise.
  """
  def invite(%Scope{organization_id: organization_id} = scope, principal_id, url_fun) do
    with {:ok, id} <- Ecto.UUID.cast(principal_id),
         %ImportedPrincipal{user_id: nil} = principal <-
           Repo.get_by(ImportedPrincipal, id: id, organization_id: organization_id),
         role when is_binary(role) <-
           returning_role(principal, held_memberships(organization_id, [id])[id]) do
      Members.invite(scope, %{"email" => principal.email, "role" => role}, url_fun,
        imported_principal_id: principal.id
      )
    else
      nil -> {:error, :not_eligible}
      _missing -> {:error, :not_found}
    end
  end

  @doc """
  Whether `email` is the address of an unlinked principal of the
  organization, so an invitation to it may bring that principal back.
  """
  def invitable?(organization_id, principal_id, email) do
    ImportedPrincipal
    |> where([principal], principal.id == ^principal_id)
    |> where([principal], principal.organization_id == ^organization_id)
    |> where([principal], is_nil(principal.user_id) and principal.email == ^email)
    |> Repo.exists?()
  end

  defp returning_role(%ImportedPrincipal{email: email}, _membership) when email in [nil, ""],
    do: nil

  defp returning_role(_principal, %{"metadata" => %{"managed_by" => _directory}}), do: nil
  defp returning_role(_principal, %{"status" => "active", "role" => role}), do: role
  defp returning_role(_principal, _membership), do: nil

  defp held_memberships(organization_id, principal_ids) do
    from(held in "imported_held_records",
      where:
        held.organization_id == type(^organization_id, :binary_id) and
          held.principal_id in type(^principal_ids, {:array, :binary_id}) and
          held.record_type == "organization_memberships",
      select: {type(held.principal_id, :binary_id), held.record}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc false
  # Called by `Renga.Members.accept_invitation/2` inside its transaction,
  # after it has checked the invitation, the account, and the inviter.
  # Returns the restored membership and what else was restored, by type.
  def restore(%OrganizationInvitation{} = invitation, %User{} = user, now) do
    case lock_unlinked(invitation) do
      %ImportedPrincipal{} = principal ->
        held = held_records(principal)
        membership = restore_membership!(invitation, user, held, now)
        links = links(invitation.organization_id, principal, user)
        ceiling = inviter_ceiling(invitation)

        applied =
          Enum.filter(held, fn {_id, type, record} ->
            restore_record?(type, record, membership, ceiling, now)
          end)

        Enum.each(applied, fn {_id, type, record} ->
          restore_record!(type, record, invitation.organization_id, user, links)
        end)

        consumed = for {id, _type, _record} <- applied, do: id
        delete_held!([membership_held_id(held) | consumed])

        principal
        |> Ecto.Changeset.change(user_id: user.id, linked_at: now)
        |> Repo.update!()

        fill_attributions!(principal, user)

        {:ok, membership, applied |> Enum.frequencies_by(&elem(&1, 1))}

      nil ->
        {:error, :invalid}
    end
  end

  defp lock_unlinked(%OrganizationInvitation{} = invitation) do
    ImportedPrincipal
    |> where([principal], principal.id == ^invitation.imported_principal_id)
    |> where([principal], principal.organization_id == ^invitation.organization_id)
    |> where([principal], is_nil(principal.user_id))
    |> where([principal], principal.email == ^invitation.email)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp held_records(%ImportedPrincipal{id: id, organization_id: organization_id}) do
    from(held in "imported_held_records",
      where:
        held.organization_id == type(^organization_id, :binary_id) and
          held.principal_id == type(^id, :binary_id),
      select: {type(held.id, :binary_id), held.record_type, held.record}
    )
    |> Repo.all()
  end

  # The held membership keeps its ID, so held team memberships and
  # assignments refer to it; the role is the invitation's.
  defp restore_membership!(invitation, user, held, now) do
    record =
      Enum.find_value(held, %{}, fn
        {_id, "organization_memberships", %{"status" => "active"} = record} -> record
        _other -> nil
      end)

    %OrganizationMembership{
      id: record["id"],
      organization_id: invitation.organization_id,
      user_id: user.id,
      role: invitation.role,
      status: "active",
      metadata: record["metadata"] || %{},
      inserted_at: time(record["inserted_at"]) || now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp membership_held_id(held) do
    Enum.find_value(held, fn
      {_id, "organization_memberships", %{"metadata" => %{"managed_by" => _directory}}} -> nil
      {id, "organization_memberships", %{"status" => "active"}} -> id
      _other -> nil
    end)
  end

  defp restore_record?("team_memberships", record, membership, _ceiling, _now),
    do: record["membership_id"] == membership.id and Repo.exists?(team(record))

  defp restore_record?("role_assignments", record, membership, ceiling, now) do
    record["membership_id"] == membership.id and record["source"] == "manual" and
      is_nil(record["expired_at"]) and current?(record["valid_until"], now) and
      within_ceiling?(record, ceiling)
  end

  defp restore_record?("saved_views", _record, _membership, _ceiling, _now), do: true
  defp restore_record?(_type, _record, _membership, _ceiling, _now), do: false

  defp team(record), do: where(Team, id: ^record["team_id"])

  defp current?(nil, _now), do: true
  defp current?(valid_until, now), do: DateTime.compare(time(valid_until), now) == :gt

  defp within_ceiling?(%{"built_in_role" => role}, ceiling) when is_binary(role),
    do: role in ceiling.roles

  defp within_ceiling?(%{"role_id" => role_id}, ceiling) do
    case Repo.get(Role, role_id) do
      %Role{permissions: permissions} -> permissions -- ceiling.permissions == []
      nil -> false
    end
  end

  # What the person who invited may grant, from their roles as they are now.
  defp inviter_ceiling(%OrganizationInvitation{} = invitation) do
    roles =
      OrganizationMembership
      |> where([membership], membership.organization_id == ^invitation.organization_id)
      |> where([membership], membership.user_id == ^invitation.invited_by_user_id)
      |> select([membership], membership.id)
      |> Repo.one!()
      |> Authorization.current_roles!()

    %{
      roles: Authorization.grantable_roles(roles),
      permissions: Authorization.grantable_permissions(roles)
    }
  end

  defp restore_record!("team_memberships", record, organization_id, _user, links) do
    Repo.insert!(%TeamMembership{
      id: record["id"],
      organization_id: organization_id,
      team_id: record["team_id"],
      membership_id: record["membership_id"],
      added_by_user_id: links.(record["added_by_user_id"]),
      inserted_at: time(record["inserted_at"])
    })
  end

  defp restore_record!("role_assignments", record, organization_id, _user, links) do
    Repo.insert!(%Assignment{
      id: record["id"],
      organization_id: organization_id,
      membership_id: record["membership_id"],
      built_in_role: record["built_in_role"],
      role_id: record["role_id"],
      valid_until: time(record["valid_until"]),
      source: record["source"],
      reason: record["reason"],
      created_by_user_id: links.(record["created_by_user_id"]),
      inserted_at: time(record["inserted_at"])
    })
  end

  defp restore_record!("saved_views", record, organization_id, user, links) do
    Repo.insert!(%SavedView{
      id: record["id"],
      organization_id: organization_id,
      user_id: user.id,
      created_by_id: links.(record["created_by_id"]),
      area: record["area"],
      name: record["name"],
      params: record["params"] || %{},
      pinned: record["pinned"] || false,
      inserted_at: time(record["inserted_at"]),
      updated_at: time(record["updated_at"])
    })
  end

  # Maps a source person to an account here: the one accepting for this
  # principal, another principal's linked account, or nobody.
  defp links(organization_id, %ImportedPrincipal{source_id: source_id}, %User{id: user_id}) do
    linked =
      ImportedPrincipal
      |> where([principal], principal.organization_id == ^organization_id)
      |> where([principal], not is_nil(principal.user_id))
      |> select([principal], {principal.source_id, principal.user_id})
      |> Repo.all()
      |> Map.new()
      |> Map.put(source_id, user_id)

    &Map.get(linked, &1)
  end

  defp delete_held!(ids) do
    ids = Enum.reject(ids, &is_nil/1)

    from(held in "imported_held_records", where: held.id in type(^ids, {:array, :binary_id}))
    |> Repo.delete_all()
  end

  # Fills the empty person fields of current records with the account. A
  # field someone has set since the import keeps its value.
  defp fill_attributions!(%ImportedPrincipal{} = principal, %User{id: user_id}) do
    fields =
      from(attribution in "imported_attributions",
        where: attribution.principal_id == type(^principal.id, :binary_id),
        distinct: true,
        select: {attribution.record_type, attribution.field}
      )
      |> Repo.all()

    for {type, field} <- fields, {type, field} in fillable() do
      Repo.query!(
        """
        UPDATE #{type} AS record SET #{field} = $1
        FROM imported_attributions AS attribution
        WHERE attribution.principal_id = $2 AND attribution.record_type = $3
          AND attribution.field = $4 AND attribution.record_id = record.id
          AND record.organization_id = $5 AND record.#{field} IS NULL
        """,
        [
          Ecto.UUID.dump!(user_id),
          Ecto.UUID.dump!(principal.id),
          type,
          field,
          Ecto.UUID.dump!(principal.organization_id)
        ]
      )
    end

    :ok
  end

  @doc false
  # Person fields of current records that linking fills, as
  # `{record type, field}`. History is never filled.
  def fillable do
    for %{part: :current} = type <- RecordTypes.all(),
        {field, _condition} <- type.principal_fields,
        {type.name, field} not in @not_filled,
        do: {type.name, field}
  end

  defp time(nil), do: nil

  defp time(value) when is_binary(value) do
    {:ok, time, _offset} = DateTime.from_iso8601(value)
    {microsecond, _precision} = time.microsecond
    %{time | microsecond: {microsecond, 6}}
  end
end
