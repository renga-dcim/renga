defmodule Renga.Limits do
  @moduledoc """
  Per-organization limits (RFD 21).

  Each limit has a built-in default, which an operator may change for the
  whole deployment through the environment and override for one
  organization with `renga-admin limits set`, which records every change in
  the deployment audit log and the organization's Activity. Organization
  owners can see their limits but never change them.

  Only limits Renga enforces are listed here; RFD 21's request, intake,
  concurrency, and quota limits join as they are enforced. Built-in defaults
  must never be met by a single-organization deployment under a large
  site's realistic load.
  """

  import Ecto.Query

  alias Renga.Accounts.Organization
  alias Renga.DeploymentAudit
  alias Renga.Inventory.ChangeEvent
  alias Renga.Limits.OrganizationLimit
  alias Renga.Repo

  @max_value 9_223_372_036_854_775_807

  @definitions [
    resources: %{
      env: "LIMIT_RESOURCES",
      default: 1_000_000,
      unit: "resource envelopes",
      description:
        "Every persisted resource, including retired and deletion-requested resources.",
      usage: {Renga.Quotas, :usage, [:resources]}
    },
    agents: %{
      env: "LIMIT_AGENTS",
      default: 100_000,
      unit: "agents",
      description: "Every registered agent, including disabled agents.",
      usage: {Renga.Quotas, :usage, [:agents]}
    },
    installation_identities: %{
      env: "LIMIT_INSTALLATION_IDENTITIES",
      default: 100_000,
      unit: "installation identities",
      description: "Every agent-bound installation UUID, regardless of approval or agent status.",
      usage: {Renga.Quotas, :usage, [:installation_identities]}
    },
    intake_keys: %{
      env: "LIMIT_INTAKE_KEYS",
      default: 10_000,
      unit: "active intake keys",
      description: "Revoking a key releases its capacity; its audit history remains.",
      usage: {Renga.Quotas, :usage, [:intake_keys]}
    },
    export_archive_bytes: %{
      env: "LIMIT_EXPORT_ARCHIVE_BYTES",
      default: 10_737_418_240,
      unit: "bytes",
      description: "Stored archives plus unused running-export reservations.",
      usage: {Renga.Quotas, :usage, [:export_archive_bytes]}
    },
    http_organization_rate: %{
      env: "LIMIT_HTTP_ORGANIZATION_RATE",
      default: 60_000,
      unit: "requests per minute",
      description: "Authenticated browser HTTP requests across the organization.",
      usage: {Renga.RequestLimits, :usage, [:http]}
    },
    http_user_rate: %{
      env: "LIMIT_HTTP_USER_RATE",
      default: 6_000,
      unit: "requests per minute per user",
      description: "HTTP requests per person in this organization; usage shows its busiest user.",
      usage: {Renga.RequestLimits, :usage, [:http, true]}
    },
    live_organization_rate: %{
      env: "LIMIT_LIVE_ORGANIZATION_RATE",
      default: 120_000,
      unit: "interactions per minute",
      description: "LiveView events and navigations across the organization.",
      usage: {Renga.RequestLimits, :usage, [:live]}
    },
    live_user_rate: %{
      env: "LIMIT_LIVE_USER_RATE",
      default: 12_000,
      unit: "interactions per minute per user",
      description: "LiveView events and navigations per person; usage shows its busiest user.",
      usage: {Renga.RequestLimits, :usage, [:live, true]}
    },
    intake_bulk_rate: %{
      env: "LIMIT_INTAKE_BULK_RATE",
      default: 60_000,
      unit: "requests per minute per node",
      description:
        "Bulk observations, telemetry, and new job leases; cannot use maintenance capacity.",
      usage: &Renga.IntakeCapacity.bulk_usage/1
    },
    intake_maintenance_rate: %{
      env: "LIMIT_INTAKE_MAINTENANCE_RATE",
      default: 60_000,
      unit: "requests per minute per node",
      description: "Reserved check-ins and already-leased job reports.",
      usage: &Renga.IntakeCapacity.maintenance_usage/1
    },
    installation_intake_rate: %{
      env: "LIMIT_INSTALLATION_INTAKE_RATE",
      default: 600,
      unit: "requests per minute per lane per node",
      description: "One installation's intake in each lane.",
      usage: &Renga.IntakeCapacity.installation_usage/1
    },
    intake_concurrency: %{
      env: "LIMIT_INTAKE_CONCURRENCY",
      default: :pool_fraction,
      unit: "operations per lane per node",
      description:
        "Admitted operations held through durable acceptance; defaults to half an intake lane, sized from the database pool.",
      usage: &Renga.IntakeCapacity.concurrency_usage/1
    },
    # Provisional development bounds. The full asynchronous fleet capacity gate
    # must establish release defaults; these numbers are not capacity evidence.
    pending_work_units: %{
      env: "LIMIT_PENDING_WORK_UNITS",
      default: 1_000_000,
      unit: "pending report, resource and target units",
      description:
        "Durably reserved until processing completes, including backoff and quarantine.",
      usage: &Renga.Inventory.ReconciliationWork.pending_units/1
    },
    pending_work_bytes: %{
      env: "LIMIT_PENDING_WORK_BYTES",
      default: 4_294_967_296,
      unit: "pending encoded evidence bytes",
      description: "Root and bounded derived payload bytes reserved before acceptance.",
      usage: &Renga.Inventory.ReconciliationWork.pending_bytes/1
    },
    job_creation_rate: %{
      env: "LIMIT_JOB_CREATION_RATE",
      default: 10_000,
      unit: "jobs per minute",
      description: "Jobs an organization may create in any one minute (RFD 9).",
      usage: &Renga.Jobs.recent_creations/1
    }
  ]

  @names Keyword.keys(@definitions)

  @doc """
  Every limit, as `{name, definition}` with `:env`, `:default`, `:unit`,
  `:description`, and `:usage`, a function of the organization ID or
  `{module, function, extra_arguments}` returning its current usage.
  """
  def definitions, do: @definitions

  def names, do: @names

  @doc "The limit named by `string`, such as `\"job_creation_rate\"`, or `:error`."
  def parse_name(string) when is_binary(string) do
    case Enum.find(@names, &(Atom.to_string(&1) == string)) do
      nil -> :error
      name -> {:ok, name}
    end
  end

  @doc """
  The deployment-wide value of `name`: the environment's setting, read into
  application configuration at boot, or the built-in default.
  """
  def default(name) when name in @names do
    :renga
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get_lazy(name, fn ->
      case @definitions[name].default do
        :pool_fraction -> Renga.IntakeCapacity.organization_size()
        value -> value
      end
    end)
  end

  @doc "The value of `name` that applies to `organization_id` now."
  def get(organization_id, name) when name in @names do
    OrganizationLimit
    |> where([limit], limit.organization_id == ^organization_id)
    |> where([limit], limit.name == ^Atom.to_string(name))
    |> select([limit], limit.value)
    |> Repo.one()
    |> Kernel.||(default(name))
  end

  @doc "Effective values from one snapshot, without a query per setting."
  def get_all(organization_id) do
    overrides =
      OrganizationLimit
      |> where([limit], limit.organization_id == ^organization_id)
      |> select([limit], {limit.name, limit.value})
      |> Repo.all()
      |> Map.new()

    Map.new(@names, fn name -> {name, Map.get(overrides, Atom.to_string(name), default(name))} end)
  end

  @doc """
  Every limit for `organization`, with its effective value, whether an
  override set it, and current usage.
  """
  def list(%Organization{id: organization_id}) do
    overrides =
      OrganizationLimit
      |> where([limit], limit.organization_id == ^organization_id)
      |> select([limit], {limit.name, limit.value})
      |> Repo.all()
      |> Map.new()

    for {name, definition} <- @definitions do
      override = Map.get(overrides, Atom.to_string(name))

      %{
        name: name,
        value: override || default(name),
        default: default(name),
        overridden?: not is_nil(override),
        usage: usage(definition.usage, organization_id),
        unit: definition.unit,
        description: definition.description
      }
    end
  end

  defp usage({module, function, args}, organization_id),
    do: apply(module, function, [organization_id | args])

  defp usage(fun, organization_id), do: fun.(organization_id)

  @doc """
  The largest value a limit can have: PostgreSQL's `bigint`, which stores
  overrides and bounds the queries that enforce them.
  """
  def max_value, do: @max_value

  @doc "Whether `value` can be a limit: an integer from 0 to `max_value/0`."
  def valid_value?(value), do: is_integer(value) and value in 0..@max_value

  @doc """
  Overrides limits for `organization` on behalf of `context`
  (`Renga.DeploymentAudit`), given as `[{name, value}]`. Either every
  setting applies or none does, and the change is recorded in the
  deployment audit log and the organization's Activity. Setting a limit
  below current usage never deletes anything; it only refuses work that
  needs more.
  """
  def set(%Organization{} = organization, settings, context) when is_list(settings) do
    DeploymentAudit.mutate(context, "limits.set", fn ->
      if valid_settings?(settings) do
        lock!(organization)

        changed = put_all!(organization, settings, context)
        {:ok, :ok, %{organization: organization, changed: changed}}
      else
        {:error, :invalid, %{organization: organization}}
      end
    end)
    |> ok()
  end

  @doc """
  Removes `organization`'s override of `name` on behalf of `context`, so the
  deployment default applies again. Clearing a limit with no override
  succeeds and changes nothing.
  """
  def clear(%Organization{} = organization, name, context) when name in @names do
    DeploymentAudit.mutate(context, "limits.clear", fn ->
      lock!(organization)

      case Repo.one(override_query(organization, name)) do
        nil ->
          {:ok, :ok, %{organization: organization}}

        override ->
          Repo.delete!(override)
          record_activity!(organization, "limit_cleared", name, context)
          {:ok, :ok, %{organization: organization, changed: [name]}}
      end
    end)
    |> ok()
  end

  defp valid_settings?(settings) do
    names = Keyword.keys(settings)

    settings != [] and names == Enum.uniq(names) and
      Enum.all?(settings, fn {name, value} -> name in @names and valid_value?(value) end)
  end

  # Serializes changes to one organization's limits, so a change that sets
  # the value already in place is recognized as no change.
  defp lock!(organization) do
    # Quota triggers lock the ledger and may insert a finding. Take the
    # parent first, matching resource creation and Activity's foreign key.
    Repo.query!("SELECT id FROM organizations WHERE id = $1 FOR KEY SHARE", [
      Ecto.UUID.dump!(organization.id)
    ])

    Repo.query!("SELECT pg_advisory_xact_lock(hashtext('renga.limits'), hashtext($1))", [
      organization.id
    ])
  end

  # Returns the names whose value changed.
  defp put_all!(organization, settings, context) do
    for {name, value} <- settings, put!(organization, name, value, context), do: name
  end

  # Returns whether the value changed.
  defp put!(organization, name, value, context) do
    case Repo.one(override_query(organization, name)) do
      %OrganizationLimit{value: ^value} ->
        false

      _other ->
        now = Renga.Time.utc_now_ms()

        Repo.insert_all(
          OrganizationLimit,
          [
            %{
              id: Ecto.UUID.generate(),
              organization_id: organization.id,
              name: Atom.to_string(name),
              value: value,
              inserted_at: now,
              updated_at: now
            }
          ],
          on_conflict: [set: [value: value, updated_at: now]],
          conflict_target: [:organization_id, :name]
        )

        record_activity!(organization, "limit_set", name, context)

        true
    end
  end

  defp override_query(organization, name) do
    OrganizationLimit
    |> where([limit], limit.organization_id == ^organization.id)
    |> where([limit], limit.name == ^Atom.to_string(name))
  end

  # The organization sees what its deployment changed and when (RFD 22,
  # "Audit"): which limit, not its value, since Activity is open to every
  # member and only owners see limit values. No person in the organization
  # made the change, so the entry names the operator rather than a user.
  defp record_activity!(organization, kind, name, context) do
    %ChangeEvent{organization_id: organization.id}
    |> ChangeEvent.changeset(%{
      kind: kind,
      field: Atom.to_string(name),
      metadata: %{"operator" => DeploymentAudit.actor_label(context)},
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()
  end

  defp ok({:ok, :ok}), do: :ok
  defp ok({:error, reason}), do: {:error, reason}
end
