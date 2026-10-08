defmodule Renga.Requests do
  @moduledoc """
  Member requests (RFD 8, "Inbox"): changes a member proposes but may not
  apply directly, decided by an owner or admin.

  Requests exist because a member lacks permission, so only members create
  them; owners and admins make the change themselves. Approving applies the
  change through the same context function an owner would call, as the
  approver, and records the requester on the request and in Activity.
  Every step (request, approval, rejection, withdrawal) is a change event
  with its actor.

  When the same change is open on several resources, `similar_requests/2`
  finds the others so an approver can decide them together.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Inventory.FieldProvenance
  alias Renga.Inventory.Host
  alias Renga.Inventory.Resource
  alias Renga.Repo
  alias Renga.Requests.Request
  alias Renga.Teams

  @lifecycle_states ~w(active inactive retired unknown)
  @per_page 50

  @doc "UI hint: members propose changes instead of applying them."
  def can_request?(%Scope{user: %{}, roles: roles}), do: "member" in (roles || [])
  def can_request?(_scope), do: false

  @doc "UI hint: owners and admins decide requests."
  def can_decide?(%Scope{} = scope), do: Inventory.organization_manager?(scope)

  ## Creating

  @doc "Proposes a lifecycle change with `%{\"value\" => state, \"reason\" => ...}`."
  def request_lifecycle(%Scope{} = scope, %Resource{} = resource, attrs) do
    create(scope, resource, "lifecycle", "", attrs)
  end

  @doc "Proposes an override of a host field with `%{\"value\" => ..., \"reason\" => ...}`."
  def request_field_override(%Scope{} = scope, %Resource{} = resource, field, attrs) do
    if field in FieldProvenance.fields(),
      do: create(scope, resource, "field_override", field, attrs),
      else: {:error, :invalid_field}
  end

  @doc """
  Proposes an owning team with `%{"value" => team_id, "reason" => ...}`. The
  request stores the team's name as its value, for display, and its id for
  approval.
  """
  def request_owner(%Scope{} = scope, %Resource{} = resource, attrs) do
    case Teams.get_team(scope, Map.get(attrs, "value")) do
      nil ->
        changeset =
          %Request{}
          |> Request.create_changeset(Map.delete(attrs, "value"))
          |> Ecto.Changeset.add_error(:after_value, "choose a team")

        {:error, changeset}

      team ->
        create(scope, resource, "owner", "", Map.put(attrs, "value", team.name), %{
          "team_id" => team.id
        })
    end
  end

  @doc "A blank changeset for a request form."
  def change_request(attrs \\ %{}), do: Ecto.Changeset.cast(%Request{}, attrs, [:reason])

  defp create(scope, resource, kind, field, attrs, extra \\ %{})

  defp create(
         %Scope{organization_id: organization_id} = scope,
         resource,
         kind,
         field,
         attrs,
         extra
       ) do
    Repo.transaction(fn ->
      authorize!(scope, ["member"])
      resource = Inventory.get_resource!(scope, resource.id)
      now = Renga.Time.utc_now_ms()

      changeset =
        %Request{
          organization_id: organization_id,
          resource_id: resource.id,
          kind: kind,
          field: field,
          before_value: before_value(scope, resource, kind, field),
          requested_by_user_id: scope.user.id
        }
        |> Request.create_changeset(attrs)
        |> merge_after_value(extra)
        |> validate_value(kind)

      with {:ok, request} <- Repo.insert(changeset),
           {:ok, _event} <- record(scope, request, "request_created", now) do
        request
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Changes.broadcast(organization_id)
  end

  @doc """
  The value the request would change, as it is now, so an approver can see
  whether it moved since the request was made.
  """
  def current_value(%Scope{} = scope, %Request{} = request) do
    resource = Inventory.get_resource!(scope, request.resource_id)
    current_value(scope, resource, request.kind, request.field)
  end

  defp current_value(_scope, resource, "lifecycle", _field), do: resource.lifecycle_state

  defp current_value(_scope, resource, "owner", _field) do
    resource = Repo.preload(resource, :owner_team)
    resource.owner_team && resource.owner_team.name
  end

  defp current_value(scope, resource, "field_override", field) do
    case Repo.get_by(Host, organization_id: scope.organization_id, resource_id: resource.id) do
      nil -> nil
      host -> Map.get(host, String.to_existing_atom(field))
    end
  end

  defp validate_value(changeset, "owner"), do: changeset

  defp validate_value(changeset, "lifecycle") do
    Ecto.Changeset.validate_change(changeset, :after_value, fn :after_value,
                                                               %{"value" => value} ->
      if value in @lifecycle_states, do: [], else: [after_value: "is not a lifecycle state"]
    end)
  end

  defp validate_value(changeset, "field_override") do
    Ecto.Changeset.validate_change(changeset, :after_value, fn :after_value,
                                                               %{"value" => value} ->
      if String.length(value) <= 255,
        do: [],
        else: [after_value: "must be at most 255 characters"]
    end)
  end

  # Owner values carry the team id beside the name, so the same team reads
  # as an unchanged value and approval does not depend on the name.
  defp before_value(_scope, %Resource{owner_team_id: team_id} = resource, "owner", _field)
       when not is_nil(team_id) do
    resource = Repo.preload(resource, :owner_team)
    %{"value" => resource.owner_team.name, "team_id" => team_id}
  end

  defp before_value(scope, resource, kind, field),
    do: wrap(current_value(scope, resource, kind, field))

  defp merge_after_value(changeset, extra) when extra == %{}, do: changeset

  defp merge_after_value(changeset, extra) do
    case Ecto.Changeset.get_change(changeset, :after_value) do
      nil -> changeset
      value -> Ecto.Changeset.put_change(changeset, :after_value, Map.merge(value, extra))
    end
  end

  defp wrap(nil), do: nil
  defp wrap(value), do: %{"value" => value}

  ## Reading

  @doc """
  Lists requests, newest first. Options: `:status` (default `"open"`, nil
  for any), `:resource_id`, and `:page`. Returns `{requests, total}`.
  """
  def list_requests(%Scope{} = scope, opts \\ []) do
    query = filtered(scope, opts)
    page = max(Keyword.get(opts, :page, 1), 1)

    requests =
      query
      |> order_by([request], desc: request.inserted_at, desc: request.id)
      |> limit(@per_page)
      |> offset(^((page - 1) * @per_page))
      |> preload([:resource, :requested_by_user, :decided_by_user])
      |> Repo.all()

    {requests, Repo.aggregate(query, :count)}
  end

  @doc "Page size used by `list_requests/2`."
  def per_page, do: @per_page

  @doc "Counts open requests in the caller's organization."
  def count_open(%Scope{} = scope), do: scope |> filtered([]) |> Repo.aggregate(:count)

  @doc "Fetches a request in the caller's organization, or nil (ids often come from a URL)."
  def get_request(%Scope{organization_id: organization_id}, id) do
    case Ecto.UUID.cast(id || "") do
      {:ok, id} ->
        Request
        |> where([request], request.organization_id == ^organization_id and request.id == ^id)
        |> preload([:resource, :requested_by_user, :decided_by_user])
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc "The open request for one change on a resource, if any."
  def open_request(%Scope{organization_id: organization_id}, resource_id, kind, field \\ "") do
    Request
    |> where([request], request.organization_id == ^organization_id)
    |> where([request], request.resource_id == ^resource_id and request.status == "open")
    |> where([request], request.kind == ^kind and request.field == ^field)
    |> preload(:requested_by_user)
    |> Repo.one()
  end

  @doc """
  Other open requests for the same change (kind, field, and proposed value)
  on other resources, so they can be approved together.
  """
  def similar_requests(%Scope{organization_id: organization_id}, %Request{} = request) do
    Request
    |> where([other], other.organization_id == ^organization_id and other.status == "open")
    |> where([other], other.id != ^request.id and other.resource_id != ^request.resource_id)
    |> where([other], other.kind == ^request.kind and other.field == ^request.field)
    |> where([other], other.after_value == ^request.after_value)
    |> order_by([other], asc: other.inserted_at)
    |> preload(:resource)
    |> Repo.all()
  end

  defp filtered(%Scope{organization_id: organization_id}, opts) do
    Request
    |> where([request], request.organization_id == ^organization_id)
    |> filter_status(Keyword.get(opts, :status, "open"))
    |> filter_resource(Keyword.get(opts, :resource_id))
  end

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: where(query, [request], request.status == ^status)

  defp filter_resource(query, nil), do: query

  defp filter_resource(query, resource_id),
    do: where(query, [request], request.resource_id == ^resource_id)

  ## Deciding

  @doc """
  Approves open requests together, applying each change as the approver.
  Either every request is approved or none is. Returns `{:ok, count}`.
  """
  def approve(%Scope{organization_id: organization_id} = scope, requests, note \\ nil) do
    Repo.transaction(fn ->
      authorize!(scope, ["owner", "admin"])
      now = Renga.Time.utc_now_ms()

      requests
      |> List.wrap()
      |> Enum.reduce(0, fn request, count ->
        approve_one(scope, request, note, now)
        count + 1
      end)
    end)
    |> Changes.broadcast(organization_id)
  end

  defp approve_one(scope, request, note, now) do
    request = lock_open!(scope, request)

    with {:ok, _applied} <- apply_change(scope, request),
         {:ok, request} <- decide(request, "approved", scope, note, now),
         {:ok, _event} <- record(scope, request, "request_approved", now) do
      request
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc "Rejects an open request, optionally saying why."
  def reject(%Scope{} = scope, %Request{} = request, note \\ nil) do
    close(scope, request, ["owner", "admin"], "rejected", note)
  end

  @doc "Withdraws an open request. Only its requester may."
  def withdraw(%Scope{} = scope, %Request{} = request) do
    close(scope, request, ["owner", "admin", "member", "viewer"], "withdrawn", nil)
  end

  defp close(%Scope{organization_id: organization_id} = scope, request, roles, status, note) do
    Repo.transaction(fn ->
      authorize!(scope, roles)
      now = Renga.Time.utc_now_ms()
      request = lock_open!(scope, request)

      if status == "withdrawn" and request.requested_by_user_id != scope.user.id,
        do: Repo.rollback(:forbidden)

      with {:ok, request} <- decide(request, status, scope, note, now),
           {:ok, _event} <- record(scope, request, "request_#{status}", now) do
        request
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Changes.broadcast(organization_id)
  end

  # Approval goes through the same functions an owner uses, so their checks
  # (resource versioning, override validation) apply unchanged.
  defp apply_change(scope, %Request{kind: "lifecycle"} = request) do
    resource = Inventory.get_resource!(scope, request.resource_id)
    Inventory.update_resource_lifecycle(scope, resource, request.after_value["value"])
  end

  defp apply_change(scope, %Request{kind: "owner"} = request) do
    resource = Inventory.get_resource!(scope, request.resource_id)
    Teams.set_owner(scope, resource, request.after_value["team_id"])
  end

  defp apply_change(scope, %Request{kind: "field_override"} = request) do
    resource = Inventory.get_resource!(scope, request.resource_id)

    Inventory.set_field_override(scope, resource, request.field, %{
      "value" => request.after_value["value"],
      "reason" => request.reason
    })
  end

  defp decide(request, status, scope, note, now) do
    request
    |> Request.decide_changeset(status, scope.user.id, note, now)
    |> Repo.update()
  end

  defp lock_open!(%Scope{organization_id: organization_id}, %Request{id: id}) do
    Request
    |> where([request], request.organization_id == ^organization_id and request.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %Request{status: "open"} = request -> request
      %Request{} -> Repo.rollback(:closed)
      nil -> Repo.rollback(:not_found)
    end
  end

  defp record(scope, request, kind, now) do
    Inventory.create_change_event(scope, %{
      kind: kind,
      field: event_field(request),
      resource_id: request.resource_id,
      old_value: request.before_value,
      new_value: request.after_value,
      metadata: %{
        "request_id" => request.id,
        "requested_by_user_id" => request.requested_by_user_id,
        "reason" => request.reason,
        "decision_note" => request.decision_note
      },
      occurred_at: now
    })
  end

  defp event_field(%Request{kind: "lifecycle"}), do: "lifecycle_state"
  defp event_field(%Request{kind: "owner"}), do: "owner_team"
  defp event_field(%Request{field: field}), do: "host." <> field

  defp authorize!(
         %Scope{
           membership_id: membership_id,
           user: %{id: user_id},
           organization_id: organization_id
         },
         roles
       )
       when not is_nil(membership_id) do
    active? =
      Organization
      |> where([organization], organization.id == ^organization_id)
      |> where([organization], organization.status == "active")
      |> lock("FOR UPDATE")
      |> Repo.exists?()

    member? =
      OrganizationMembership
      |> where([membership], membership.id == ^membership_id)
      |> where([membership], membership.user_id == ^user_id)
      |> where([membership], membership.organization_id == ^organization_id)
      |> where([membership], membership.status == "active" and membership.role in ^roles)
      |> lock("FOR UPDATE")
      |> Repo.exists?()

    unless active? and member?, do: Repo.rollback(:forbidden)
  end

  defp authorize!(%Scope{}, _roles), do: Repo.rollback(:forbidden)
end
