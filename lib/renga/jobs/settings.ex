defmodule Renga.Jobs.Settings do
  @moduledoc """
  An organization's job settings, stored under `"jobs"` in its settings map.

  Until an owner sets them, an organization allows every registered `observe`
  capability except queries, which RFD 12 keeps off until enabled one by one,
  and no `operate` or `interactive` one, and keeps job history for 90 days
  (RFD 9). Deriving the default on read, rather than writing it at
  creation, means existing organizations get it too and a newly registered
  `observe` capability is allowed without a migration.
  """

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Jobs.Registry

  @default_retention_days 90
  @max_retention_days 3650

  @doc "The `name@version` keys this organization lets anyone target."
  def allowed_capabilities(%Organization{settings: settings}) do
    case get_in(settings || %{}, ["jobs", "allowed_capabilities"]) do
      allowed when is_list(allowed) -> allowed
      _default -> Registry.default_allowed_keys()
    end
  end

  @doc "Days a finished job and its events are kept."
  def retention_days(%Organization{settings: settings}) do
    case get_in(settings || %{}, ["jobs", "retention_days"]) do
      days when is_integer(days) and days > 0 -> days
      _default -> @default_retention_days
    end
  end

  def default_retention_days, do: @default_retention_days

  @doc """
  Validates new job settings. `allowed_capabilities` must name registered
  capabilities; any omitted field keeps its current value.
  """
  def changeset(%Organization{} = organization, attrs) do
    current = %{
      allowed_capabilities: allowed_capabilities(organization),
      retention_days: retention_days(organization)
    }

    {current, %{allowed_capabilities: {:array, :string}, retention_days: :integer}}
    |> cast(attrs, [:allowed_capabilities, :retention_days])
    |> validate_required([:allowed_capabilities, :retention_days])
    |> validate_number(:retention_days,
      greater_than: 0,
      less_than_or_equal_to: @max_retention_days
    )
    |> validate_change(:allowed_capabilities, fn :allowed_capabilities, keys ->
      case Enum.reject(keys, &(&1 in Registry.keys())) do
        [] -> []
        unknown -> [allowed_capabilities: "unknown capabilities: #{Enum.join(unknown, ", ")}"]
      end
    end)
    |> update_change(:allowed_capabilities, &Enum.uniq/1)
  end

  @doc "The organization settings map with validated job settings merged in."
  def put(%Organization{settings: settings}, %{} = job_settings) do
    Map.put(settings || %{}, "jobs", %{
      "allowed_capabilities" => job_settings.allowed_capabilities,
      "retention_days" => job_settings.retention_days
    })
  end
end
