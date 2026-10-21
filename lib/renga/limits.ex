defmodule Renga.Limits do
  @moduledoc """
  Per-organization limits (RFD 21).

  Each limit has a built-in default, which an operator may change for the
  whole deployment through the environment and override for one
  organization with `renga-admin limits set`. Organization owners can see
  their limits but never change them.

  Only limits Renga enforces are listed here; RFD 21's request, intake,
  concurrency, and quota limits join as they are enforced. Built-in defaults
  must never be met by a single-organization deployment under a large
  site's realistic load.
  """

  import Ecto.Query

  alias Renga.Accounts.Organization
  alias Renga.Limits.OrganizationLimit
  alias Renga.Repo

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
  Overrides `name` for `organization`. Setting a limit below current usage
  never deletes anything; it only refuses work that needs more.
  """
  def set(%Organization{id: organization_id}, name, value)
      when name in @names and is_integer(value) and value >= 0 do
    now = Renga.Time.utc_now_ms()

    Repo.insert_all(
      OrganizationLimit,
      [
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          name: Atom.to_string(name),
          value: value,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: [set: [value: value, updated_at: now]],
      conflict_target: [:organization_id, :name]
    )

    :ok
  end

  @doc "Removes `organization`'s override of `name`, so the default applies again."
  def clear(%Organization{id: organization_id}, name) when name in @names do
    OrganizationLimit
    |> where([limit], limit.organization_id == ^organization_id)
    |> where([limit], limit.name == ^Atom.to_string(name))
    |> Repo.delete_all()

    :ok
  end
end
