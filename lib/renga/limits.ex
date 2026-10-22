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
  `:description`, and `:usage`, a function of the organization ID returning
  its current usage.
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
    |> Keyword.get_lazy(name, fn -> @definitions[name].default end)
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
        usage: definition.usage.(organization_id),
        unit: definition.unit,
        description: definition.description
      }
    end
  end

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
      if settings != [] and
           Enum.all?(settings, fn {name, value} -> name in @names and valid_value?(value) end) do
        lock!(organization)

        changed =
          for {name, value} <- settings, put!(organization, name, value, context), do: name

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
          record_activity!(organization, "limit_cleared", name, override.value, nil, context)
          {:ok, :ok, %{organization: organization, changed: [name]}}
      end
    end)
    |> ok()
  end

  # Serializes changes to one organization's limits, so each Activity entry
  # has the value it really replaced.
  defp lock!(organization) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext('renga.limits'), hashtext($1))", [
      organization.id
    ])
  end

  # Returns whether the value changed.
  defp put!(organization, name, value, context) do
    case Repo.one(override_query(organization, name)) do
      %OrganizationLimit{value: ^value} ->
        false

      existing ->
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

        record_activity!(
          organization,
          "limit_set",
          name,
          existing && existing.value,
          value,
          context
        )

        true
    end
  end

  defp override_query(organization, name) do
    OrganizationLimit
    |> where([limit], limit.organization_id == ^organization.id)
    |> where([limit], limit.name == ^Atom.to_string(name))
  end

  # The organization's owners see what their deployment changed and when
  # (RFD 22, "Audit"). No person in the organization made the change, so the
  # entry names the operator rather than a user.
  defp record_activity!(organization, kind, name, old, new, context) do
    %ChangeEvent{organization_id: organization.id}
    |> ChangeEvent.changeset(%{
      kind: kind,
      field: Atom.to_string(name),
      old_value: old && %{"value" => old},
      new_value: new && %{"value" => new},
      metadata: %{"operator" => DeploymentAudit.actor_label(context)},
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()
  end

  defp ok({:ok, :ok}), do: :ok
  defp ok({:error, reason}), do: {:error, reason}
end
