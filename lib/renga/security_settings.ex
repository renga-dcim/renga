defmodule Renga.SecuritySettings do
  @moduledoc """
  An organization's security settings (RFD 19, "Security settings").

  Renga always enforces what makes a feature safe to exist at all; anything
  beyond that is a setting here, off by default unless RFD 19 says
  otherwise, that the organization's owners choose to turn on. Changing one
  needs `organization.manage`. Each change is recorded in Activity with the
  actor, the before and after values, and the reason given, and the setting
  remembers who last changed it.

  A setting that adds a requirement applies at each member's next request
  to the organization; changing one never signs anyone out.

  Only settings Renga enforces are listed; the others in RFD 19's table join
  as the features they govern ship. Operator defaults and locks (RFD 22)
  arrive with the operator policy API.
  """

  import Ecto.Query

  alias Renga.Accounts.Scope
  alias Renga.Accounts.User
  alias Renga.Authorization
  alias Renga.Inventory
  alias Renga.Repo
  alias Renga.SecuritySettings.Setting

  @definitions [
    require_mfa: %{
      type: :boolean,
      default: false,
      label: "Require multi-factor authentication",
      description:
        "Members open this organization only after a passkey, an authenticator code, " <>
          "or an identity provider marked as enforcing MFA."
    }
  ]

  @names Keyword.keys(@definitions)

  @doc "Every setting, as `{name, definition}` with `:type`, `:default`, `:label`, and `:description`."
  def definitions, do: @definitions

  @doc "The setting named by `string`, such as `\"require_mfa\"`, or `:error`."
  def parse_name(string) when is_binary(string) do
    case Enum.find(@names, &(Atom.to_string(&1) == string)) do
      nil -> :error
      name -> {:ok, name}
    end
  end

  @doc "The value of `name` that applies to `organization_id` now."
  def get(organization_id, name) when is_binary(organization_id) and name in @names do
    Setting
    |> where(organization_id: ^organization_id, name: ^Atom.to_string(name))
    |> select([setting], setting.value)
    |> Repo.one()
    |> unwrap(name)
  end

  @doc "Whether members must use a second factor to open `organization_id`."
  def require_mfa?(organization_id), do: get(organization_id, :require_mfa)

  @doc """
  Every setting for the scope's organization: its value, whether it is the
  default, and who last changed it and when (nil while it never changed).
  """
  def list(%Scope{organization_id: organization_id}) when is_binary(organization_id) do
    stored =
      Setting
      |> where(organization_id: ^organization_id)
      |> Repo.all()
      |> Map.new(&{&1.name, &1})

    for {name, definition} <- @definitions do
      setting = Map.get(stored, Atom.to_string(name))

      Map.merge(definition, %{
        name: name,
        value: unwrap(setting && setting.value, name),
        changed_by: setting && setting.changed_by,
        changed_at: setting && setting.updated_at
      })
    end
  end

  @doc """
  Sets `name` to `value` for the scope's organization, recording the change
  in Activity with `reason` (optional). Setting the value already in place
  records nothing. Returns `{:ok, value}`, `{:error, :forbidden}` without
  `organization.manage`, or `{:error, :invalid}` for a value of the wrong
  type.
  """
  def put(scope, name, value, reason \\ nil)

  def put(
        %Scope{user: %User{} = user, organization_id: organization_id} = scope,
        name,
        value,
        reason
      )
      when is_binary(organization_id) and name in @names do
    if valid_value?(name, value),
      do: Repo.transaction(fn -> change!(scope, user, name, value, reason) end),
      else: {:error, :invalid}
  end

  def put(_scope, _name, _value, _reason), do: {:error, :forbidden}

  defp change!(scope, user, name, value, reason) do
    # Locks the organization too, so changes to its settings serialize.
    Authorization.authorize!(scope, "organization.manage")
    old = get(scope.organization_id, name)
    if old != value, do: record_change!(scope, user, name, old, value, reason)
    value
  end

  defp record_change!(scope, user, name, old, value, reason) do
    now = Renga.Time.utc_now_ms()

    Repo.insert_all(
      Setting,
      [
        %{
          id: Ecto.UUID.generate(),
          organization_id: scope.organization_id,
          name: Atom.to_string(name),
          value: %{"value" => value},
          changed_by_user_id: user.id,
          changed_by: user.email,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:value, :changed_by_user_id, :changed_by, :updated_at]},
      conflict_target: [:organization_id, :name]
    )

    {:ok, _event} =
      Inventory.create_change_event(scope, %{
        kind: "security_setting_changed",
        field: Atom.to_string(name),
        old_value: %{"value" => old},
        new_value: %{"value" => value},
        metadata: reason_metadata(reason)
      })
  end

  defp valid_value?(name, value) do
    case @definitions[name].type do
      :boolean -> is_boolean(value)
    end
  end

  defp unwrap(%{"value" => value}, _name), do: value
  defp unwrap(nil, name), do: @definitions[name].default

  defp reason_metadata(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> %{}
      reason -> %{"reason" => String.slice(reason, 0, 500)}
    end
  end

  defp reason_metadata(_reason), do: %{}
end
