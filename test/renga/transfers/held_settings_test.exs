defmodule Renga.Transfers.HeldSettingsTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Accounts.Organization
  alias Renga.Accounts.SessionMFA
  alias Renga.Inventory.ChangeEvent
  alias Renga.Jobs
  alias Renga.SecuritySettings
  alias Renga.SecuritySettings.Setting
  alias Renga.Transfers.HeldSettings
  alias Renga.Transfers.OrganizationImport

  setup do
    %{organization: organization, scope: owner} = job_organization_fixture()
    # The organization requires MFA, so the owner signed in with a passkey.
    owner = %{owner | user: %{owner.user | session_mfa: SessionMFA.for_method(:passkey)}}
    operate = Jobs.Registry.keys_with_risk(:operate) |> List.first()

    Repo.insert!(%Setting{
      organization_id: organization.id,
      name: "require_mfa",
      value: %{"value" => true},
      changed_by: "owner@example.com"
    })

    import =
      Repo.insert!(%OrganizationImport{
        organization_id: organization.id,
        source_organization_id: Ecto.UUID.generate(),
        source_slug: "acme",
        source_name: "Acme",
        format_version: 1,
        renga_version: "0.1.0",
        snapshot_at: Renga.Time.utc_now_ms(),
        records: 1,
        sha256: String.duplicate("0", 64),
        held_settings: %{
          "jobs" => %{"allowed_capabilities" => [operate, "nothing.known@1"]},
          "security" => %{"require_mfa" => false},
          "unknown" => true
        }
      })

    %{organization: organization, owner: owner, import: import, operate: operate}
  end

  defp items(scope) do
    assert {:ok, [{_import, items}]} = HeldSettings.list(scope)
    items
  end

  defp key(scope, path), do: Enum.find(items(scope), &(&1.path == path)).key

  defp held(import), do: Repo.get!(OrganizationImport, import.id).held_settings

  defp activity(organization, kinds) do
    ChangeEvent
    |> where([event], event.organization_id == ^organization.id and event.kind in ^kinds)
    |> order_by([event], asc: event.inserted_at, asc: event.id)
    |> select([event], {event.kind, event.field, event.metadata})
    |> Repo.all()
  end

  test "lists each held setting, security first, with whether it can be applied", context do
    title = Jobs.Registry.fetch(context.operate) |> elem(1) |> then(& &1.title())

    assert [
             %{label: "Require multi-factor authentication: off", applied?: true},
             %{label: "Allow " <> ^title, applied?: true},
             %{label: "Allow nothing.known@1", applied?: false},
             %{label: "Setting unknown", applied?: false}
           ] = items(context.owner)
  end

  test "confirming a capability allows it and takes it off the import", context do
    %{owner: owner, organization: organization, import: import, operate: operate} = context
    key = key(owner, ["jobs", "allowed_capabilities", operate])

    assert {:ok, %{path: ["jobs", "allowed_capabilities", ^operate]}} =
             HeldSettings.confirm(owner, import.id, key)

    assert operate in Jobs.Settings.allowed_capabilities(Repo.get!(Organization, organization.id))
    assert held(import)["jobs"] == %{"allowed_capabilities" => ["nothing.known@1"]}

    assert [
             {"capability_allowed", ^operate, _},
             {"import_setting_confirmed", field, %{"source" => "acme", "import_id" => id}}
           ] = activity(organization, ~w(capability_allowed import_setting_confirmed))

    assert field == "jobs.allowed_capabilities.#{operate}" and id == import.id
    assert {:error, :not_found} = HeldSettings.confirm(owner, import.id, key)
  end

  test "confirming a security setting changes it with a reason that names the import",
       context do
    %{owner: owner, organization: organization, import: import} = context

    assert {:ok, _item} =
             HeldSettings.confirm(owner, import.id, key(owner, ["security", "require_mfa"]))

    refute SecuritySettings.require_mfa?(organization.id)
    refute Map.has_key?(held(import), "security")

    assert [{"security_setting_changed", "require_mfa", %{"reason" => reason}} | _] =
             activity(organization, ~w(security_setting_changed))

    assert reason == "Confirmed from the import of acme"
  end

  test "a setting this release cannot apply can only be dismissed", context do
    %{owner: owner, organization: organization, import: import} = context
    key = key(owner, ["unknown"])

    assert {:error, :unsupported} = HeldSettings.confirm(owner, import.id, key)
    assert held(import)["unknown"] == true

    assert {:ok, %{label: "Setting unknown"}} = HeldSettings.dismiss(owner, import.id, key)
    refute Map.has_key?(held(import), "unknown")

    assert [{"import_setting_dismissed", "unknown", %{"label" => "Setting unknown"}}] =
             activity(organization, ~w(import_setting_confirmed import_setting_dismissed))
  end

  test "an import with nothing left held is no longer listed", context do
    %{owner: owner, import: import} = context

    for item <- items(owner),
        do: assert({:ok, _} = HeldSettings.dismiss(owner, import.id, item.key))

    assert held(import) == %{}
    assert {:ok, []} = HeldSettings.list(owner)
    assert SecuritySettings.require_mfa?(context.organization.id)
  end

  test "every action needs organization.manage and names a held setting", context do
    %{owner: owner, organization: organization, import: import} = context
    admin = member_scope(organization, "admin")
    key = key(owner, ["security", "require_mfa"])

    assert {:error, :forbidden} = HeldSettings.list(admin)
    assert {:error, :forbidden} = HeldSettings.confirm(admin, import.id, key)
    assert {:error, :forbidden} = HeldSettings.dismiss(admin, import.id, key)

    assert {:error, :not_found} = HeldSettings.confirm(owner, import.id, ~s(["security","x"]))
    assert {:error, :not_found} = HeldSettings.dismiss(owner, import.id, "not json")
    assert {:error, :not_found} = HeldSettings.dismiss(owner, Ecto.UUID.generate(), key)

    other = job_organization_fixture()
    assert {:error, :not_found} = HeldSettings.dismiss(other.scope, import.id, key)
    assert SecuritySettings.require_mfa?(organization.id)
  end
end
