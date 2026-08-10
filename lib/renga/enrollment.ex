defmodule Renga.Enrollment do
  @moduledoc "Organization-scoped administration of immutable enrollment versions and selectors."

  import Ecto.Query, warn: false

  alias Renga.Accounts.{Organization, OrganizationMembership, Scope}
  alias Renga.Enrollment.{EnrollmentPolicy, EnrollmentProfile, VerifierConfiguration}
  alias Renga.Repo

  def list_profiles(%Scope{organization_id: id}),
    do: scoped(EnrollmentProfile, id) |> order_by([r], r.selector) |> Repo.all()

  def list_policies(%Scope{organization_id: id}),
    do:
      scoped(EnrollmentPolicy, id)
      |> order_by([r], desc: r.version, asc: r.name, desc: r.inserted_at)
      |> Repo.all()

  def list_verifier_configurations(%Scope{organization_id: id}),
    do:
      scoped(VerifierConfiguration, id)
      |> order_by([r], desc: r.version, asc: r.name, desc: r.inserted_at)
      |> Repo.all()

  def get_profile!(%Scope{organization_id: id}, row_id),
    do: scoped(EnrollmentProfile, id) |> Repo.get!(row_id)

  def get_policy!(%Scope{organization_id: id}, row_id),
    do: scoped(EnrollmentPolicy, id) |> Repo.get!(row_id)

  def get_verifier_configuration!(%Scope{organization_id: id}, row_id),
    do: scoped(VerifierConfiguration, id) |> Repo.get!(row_id)

  def create_policy(%Scope{} = scope, attrs) do
    admin_transaction(scope, fn ->
      name = fetch_attr(attrs, :name)

      %EnrollmentPolicy{
        organization_id: scope.organization_id,
        created_by_membership_id: scope.membership_id
      }
      |> EnrollmentPolicy.changeset(
        put_attr(attrs, :version, next_version(EnrollmentPolicy, scope.organization_id, name))
      )
      |> Repo.insert()
    end)
  end

  def create_verifier_configuration(%Scope{} = scope, attrs) do
    admin_transaction(scope, fn ->
      name = fetch_attr(attrs, :name)

      %VerifierConfiguration{
        organization_id: scope.organization_id,
        created_by_membership_id: scope.membership_id
      }
      |> VerifierConfiguration.changeset(
        put_attr(
          attrs,
          :version,
          next_version(VerifierConfiguration, scope.organization_id, name)
        )
      )
      |> Repo.insert()
    end)
  end

  def create_profile(%Scope{} = scope, attrs) do
    admin_transaction(scope, fn ->
      %EnrollmentProfile{organization_id: scope.organization_id}
      |> EnrollmentProfile.changeset(attrs)
      |> Repo.insert()
    end)
  end

  def disable_profile(%Scope{} = scope, id),
    do: disable(scope, EnrollmentProfile, id, &EnrollmentProfile.disable_changeset/2)

  def disable_verifier_configuration(%Scope{} = scope, id),
    do: disable(scope, VerifierConfiguration, id, &VerifierConfiguration.disable_changeset/2)

  defp disable(scope, schema, id, changeset) do
    admin_transaction(scope, fn ->
      case scoped(schema, scope.organization_id)
           |> where([r], r.id == ^id)
           |> lock("FOR UPDATE")
           |> Repo.one() do
        nil -> Repo.rollback(:not_found)
        row -> row |> changeset.(Renga.Time.utc_now_ms()) |> Repo.update()
      end
    end)
  end

  defp next_version(schema, organization_id, name) do
    schema
    |> where([r], r.organization_id == ^organization_id)
    |> where([r], r.name == ^name)
    |> select([r], coalesce(max(r.version), 0) + 1)
    |> Repo.one()
  end

  defp fetch_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp put_attr(attrs, key, value) do
    if Enum.all?(Map.keys(attrs), &is_binary/1) do
      Map.put(attrs, Atom.to_string(key), value)
    else
      Map.put(attrs, key, value)
    end
  end

  defp scoped(schema, organization_id),
    do: where(schema, [r], r.organization_id == ^organization_id)

  defp admin_transaction(%Scope{} = scope, operation) do
    Repo.transaction(fn ->
      active_org =
        Organization
        |> where([o], o.id == ^scope.organization_id and o.status == "active")
        |> lock("FOR UPDATE")
        |> Repo.exists?()

      authorized =
        OrganizationMembership
        |> where(
          [m],
          m.id == ^scope.membership_id and m.organization_id == ^scope.organization_id
        )
        |> where(
          [m],
          m.user_id == ^user_id(scope) and m.status == "active" and m.role in ["owner", "admin"]
        )
        |> lock("FOR UPDATE")
        |> Repo.exists?()

      unless active_org and authorized, do: Repo.rollback(:forbidden)

      case operation.() do
        {:ok, row} -> row
        {:error, reason} -> Repo.rollback(reason)
        row -> row
      end
    end)
  end

  defp user_id(%Scope{user: %{id: id}}), do: id
  defp user_id(_scope), do: nil
end
