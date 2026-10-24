defmodule Renga.Transfers.HeldSettings do
  @moduledoc """
  Settings an import held for an owner to confirm (RFD 20).

  An import applies a source setting only where it does not weaken the
  destination; the rest wait in the import's `held_settings`. Each one is
  an item here:

    * a capability the destination does not allow, from
      `jobs.allowed_capabilities`;
    * a security setting that would remove a requirement, from `security`;
    * a setting this release does not know, which can only be dismissed.

  Confirming applies a setting through the function a person uses to change
  it (`Renga.Jobs.allow_capability/3`, `Renga.SecuritySettings.put/4`), so
  it needs the same permission, `organization.manage`, and is refused
  wherever that function refuses. Confirming or dismissing takes the item
  off the import and records it in Activity.
  """

  import Ecto.Query

  alias Renga.Accounts.Scope
  alias Renga.Authorization
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Changes
  alias Renga.Jobs
  alias Renga.Repo
  alias Renga.SecuritySettings
  alias Renga.Transfers.OrganizationImport

  # Security settings first, as the ones that weaken the most.
  @order %{"security" => 0, "jobs" => 1}

  @doc """
  The organization's imports that still hold settings, newest first, each as
  `{import, items}`. An item has a `:key` to confirm or dismiss it by, a
  `:label`, and whether it can be `:applied?` by this release.
  """
  def list(%Scope{} = scope) do
    Repo.transaction(fn ->
      Authorization.authorize!(scope, "organization.manage")

      OrganizationImport
      |> where([import], import.organization_id == ^scope.organization_id)
      |> where([import], import.held_settings != ^%{})
      |> order_by([import], desc: import.inserted_at, desc: import.id)
      |> Repo.all()
      |> Enum.map(&{&1, items(&1.held_settings)})
    end)
  end

  @doc """
  Applies the held setting `key` of the import `import_id` and takes it off
  the import. Returns `{:ok, item}`, `{:error, :not_found}` when the import
  no longer holds it, `{:error, :unsupported}` for a setting this release
  cannot apply, or what applying it returned, such as `{:error, :forbidden}`.
  """
  def confirm(%Scope{} = scope, import_id, key),
    do: resolve(scope, import_id, key, "import_setting_confirmed")

  @doc """
  Takes the held setting `key` off the import `import_id` without applying
  it. Returns `{:ok, item}` or `{:error, :not_found}`.
  """
  def dismiss(%Scope{} = scope, import_id, key),
    do: resolve(scope, import_id, key, "import_setting_dismissed")

  defp resolve(scope, import_id, key, kind) do
    with {:ok, path} <- decode(key), {:ok, import_id} <- Ecto.UUID.cast(import_id) do
      Repo.transaction(fn -> resolve!(scope, import_id, path, kind) end)
      |> Changes.broadcast(scope.organization_id)
    else
      _invalid -> {:error, :not_found}
    end
  end

  defp resolve!(scope, import_id, path, kind) do
    # Locks the organization first, as every settings change does.
    Authorization.authorize!(scope, "organization.manage")
    import = locked_import!(scope, import_id)
    item = Enum.find(items(import.held_settings), &(&1.path == path)) || not_found()
    if kind == "import_setting_confirmed", do: apply!(scope, import, item)

    import
    |> Ecto.Changeset.change(held_settings: drop(import.held_settings, path))
    |> Repo.update!()

    record!(scope, import, item, kind)
    item
  end

  defp locked_import!(scope, import_id) do
    OrganizationImport
    |> where([import], import.organization_id == ^scope.organization_id)
    |> where([import], import.id == ^import_id)
    |> lock("FOR UPDATE")
    |> Repo.one() || not_found()
  end

  defp not_found, do: Repo.rollback(:not_found)

  defp apply!(scope, _import, %{path: ["jobs", "allowed_capabilities", key], applied?: true}),
    do: applied!(Jobs.allow_capability(scope, key, true))

  defp apply!(scope, import, %{path: ["security", name], value: value, applied?: true}) do
    {:ok, name} = SecuritySettings.parse_name(name)
    reason = "Confirmed from the import of #{import.source_slug}"
    applied!(SecuritySettings.put(scope, name, value, reason))
  end

  defp apply!(_scope, _import, _item), do: Repo.rollback(:unsupported)

  defp applied!({:ok, _result}), do: :ok
  defp applied!({:error, reason}), do: Repo.rollback(reason)

  defp record!(scope, import, item, kind) do
    %ChangeEvent{organization_id: scope.organization_id, actor_user_id: scope.user.id}
    |> ChangeEvent.changeset(%{
      kind: kind,
      field: Enum.join(item.path, "."),
      new_value: %{"value" => item.value},
      metadata: %{
        "import_id" => import.id,
        "source" => import.source_slug,
        "label" => item.label
      },
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()
  end

  ## Items

  defp items(held) do
    held
    |> Enum.sort_by(fn {group, _value} -> {Map.get(@order, group, 2), group} end)
    |> Enum.flat_map(fn {group, value} -> group_items(group, value) end)
  end

  defp group_items("security", settings) when is_map(settings) do
    for {name, value} <- Enum.sort(settings) do
      case SecuritySettings.parse_name(name) do
        {:ok, parsed} ->
          definition = SecuritySettings.definitions()[parsed]
          item(["security", name], value, "#{definition.label}: #{on_off(value)}", true)

        :error ->
          item(["security", name], value, "Security setting #{name}", false)
      end
    end
  end

  defp group_items("jobs", jobs) when is_map(jobs) do
    for {setting, value} <- Enum.sort(jobs), item <- job_items(setting, value), do: item
  end

  defp group_items(group, value), do: [item([group], value, "Setting #{group}", false)]

  defp job_items("allowed_capabilities", keys) when is_list(keys) do
    for key <- keys do
      case Jobs.Registry.fetch(key) do
        {:ok, capability} ->
          item(["jobs", "allowed_capabilities", key], key, "Allow #{capability.title()}", true)

        {:error, _unknown} ->
          item(["jobs", "allowed_capabilities", key], key, "Allow #{key}", false)
      end
    end
  end

  defp job_items(setting, value),
    do: [item(["jobs", setting], value, "Job setting #{setting}", false)]

  defp item(path, value, label, applied?) do
    %{key: Jason.encode!(path), path: path, value: value, label: label, applied?: applied?}
  end

  defp on_off(true), do: "on"
  defp on_off(false), do: "off"
  defp on_off(value), do: inspect(value)

  defp decode(key) when is_binary(key) do
    case Jason.decode(key) do
      {:ok, [_ | _] = path} -> if Enum.all?(path, &is_binary/1), do: {:ok, path}, else: :error
      _invalid -> :error
    end
  end

  defp decode(_key), do: :error

  # Takes `path` out of the held settings, dropping what it leaves empty.
  defp drop(map, [key]) when is_map(map), do: Map.delete(map, key)
  defp drop(list, [item]) when is_list(list), do: List.delete(list, item)

  defp drop(map, [key | rest]) when is_map(map) do
    case drop(Map.fetch!(map, key), rest) do
      empty when empty in [%{}, []] -> Map.delete(map, key)
      value -> Map.put(map, key, value)
    end
  end
end
