defmodule Renga.Quotas do
  @moduledoc """
  Persisted organization capacity accounting (RFD 21).

  Domain rows are the idempotent owners: successful resource/agent/key
  mutations charge counts, and an export row reserves its declared maximum.
  Database triggers update the ledger in the same transaction, including bulk
  SQL and imports. A failed mutation rolls back its charge. Retiring a resource
  or disabling an agent does not free capacity; physical deletion does.

  Export reservations survive restart. Ending generation releases only unused
  bytes; retained bytes stay charged until their chunks are actually deleted.
  New reservation types must use the same `renga_charge_quota` transition under
  their durable owner's row lock, not call it as an independent counter.
  """
  import Ecto.Query

  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.Scope
  alias Renga.Repo

  @names [:resources, :agents, :installation_identities, :intake_keys, :export_archive_bytes]
  def names, do: @names

  # Runs after Repo and before any worker or endpoint. Migrations can create
  # a fresh database before the application has its accounting tables.
  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}

  def start_link(_opts) do
    configure_defaults()
    :ignore
  end

  @doc "Publishes deployment defaults for database-enforced checks, including repo-only commands."
  def configure_defaults do
    if Repo.query!("SELECT to_regclass('organization_quota_defaults')").rows != [[nil]] do
      for name <- @names do
        Repo.query!(
          """
          INSERT INTO organization_quota_defaults(name, value) VALUES ($1, $2)
          ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value
          WHERE organization_quota_defaults.value IS DISTINCT FROM EXCLUDED.value
          """,
          [Atom.to_string(name), Renga.Limits.default(name)]
        )
      end
    end

    :ok
  end

  @doc "Capacity held now: retained/used units plus unused reservations."
  def usage(organization_id, name) when name in @names do
    %{rows: rows} =
      Repo.query!(
        "SELECT used + reserved FROM organization_quota_usage WHERE organization_id = $1 AND name = $2",
        [Ecto.UUID.dump!(organization_id), Atom.to_string(name)]
      )

    case rows do
      [[usage]] -> usage
      [] -> 0
    end
  end

  @doc "Maps a database quota refusal to a caller-visible changeset error."
  def constrain(changeset, name, field \\ :base) when name in @names do
    Ecto.Changeset.check_constraint(changeset, field,
      name: "renga_quota_#{name}_exceeded",
      message: "#{name} quota exceeded"
    )
  end

  @doc "Distinguishes quota exhaustion after a failed canonical transaction."
  def exceeded?(%Ecto.Changeset{errors: errors}, name) when name in @names do
    Enum.any?(errors, fn {_field, {_message, options}} ->
      options[:constraint_name] == "renga_quota_#{name}_exceeded"
    end)
  end

  def exceeded?(%Postgrex.Error{postgres: postgres}, name) when name in @names,
    do: postgres[:constraint] == "renga_quota_#{name}_exceeded"

  def exceeded?(_reason, _name), do: false

  @doc "Checks current ownership rather than a connected page's cached roles."
  def owner?(%Scope{membership_id: membership_id, user: %{id: user_id}} = scope)
      when not is_nil(membership_id) do
    now = Renga.Time.utc_now_ms()

    owners =
      from assignment in Renga.Roles.Assignment,
        where: assignment.built_in_role == "owner",
        where: is_nil(assignment.valid_until) or assignment.valid_until > ^now,
        select: assignment.membership_id

    Repo.exists?(
      from membership in OrganizationMembership,
        where: membership.id == ^membership_id and membership.user_id == ^user_id,
        where: membership.organization_id == ^scope.organization_id,
        where: membership.status == "active",
        where: membership.role == "owner" or membership.id in subquery(owners)
    )
  end

  def owner?(_scope), do: false

  @doc "Owner-only quota findings, opened at 80% and resolved when usage falls."
  def findings(%Scope{organization_id: organization_id} = scope) do
    if owner?(scope) do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT id, name, used, capacity, opened_at FROM organization_quota_findings
          WHERE organization_id = $1 AND resolved_at IS NULL ORDER BY name
          """,
          [Ecto.UUID.dump!(organization_id)]
        )

      Enum.map(rows, fn [id, name, used, capacity, opened_at] ->
        %{
          id: Ecto.UUID.load!(id),
          name: name,
          used: used,
          capacity: capacity,
          opened_at: opened_at
        }
      end)
    else
      []
    end
  end
end
