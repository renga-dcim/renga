defmodule Renga.Inventory.ChangeEvent do
  @moduledoc """
  Append-only audit record for inventory state transitions.

  Change events are intentionally small and field-oriented so later UI and
  alerting code can explain when resources appeared, changed, conflicted, or
  became stale. `actor_user_id` names the person behind a change; it is nil
  for changes reconciliation made from collector reports.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.Source
  alias Renga.Inventory.SyncRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(created deleted discovered updated conflict stale manual_override override_removed
             finding_assigned finding_snoozed finding_exception finding_exception_removed
             request_created request_approved request_rejected request_withdrawn
             owner_changed rule_applied job_requested job_outcome
             member_role_changed member_disabled member_enabled
             member_invited invitation_revoked member_joined
             team_member_added team_member_removed role_created role_updated role_deleted
             role_assigned role_unassigned role_expired limit_set limit_cleared withdrawn
             organization_created
             scim_connection_created scim_connection_disabled scim_connection_enabled
             scim_default_role_changed scim_token_created scim_token_revoked
             scim_user_created scim_user_updated scim_user_deleted
             scim_group_created scim_group_updated scim_group_deleted
             scim_user_linked scim_link_refused scim_group_mapped
             scim_grant_added scim_grant_changed scim_grant_removed
             identity_provider_changed organization_domain_changed security_setting_changed
             capability_allowed capability_disallowed)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "change_events" do
    field :kind, :string
    field :field, :string
    field :old_value, :map
    field :new_value, :map
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :resource, Resource
    belongs_to :source, Source
    belongs_to :sync_run, SyncRun
    belongs_to :observation, Observation
    belongs_to :actor_user, Renga.Accounts.User
    belongs_to :finding_workflow, Renga.Findings.Workflow

    timestamps()
  end

  def changeset(change_event, attrs) do
    change_event
    |> cast(attrs, [:kind, :field, :old_value, :new_value, :metadata, :occurred_at])
    |> update_change(:field, &trim_string/1)
    |> validate_required([:organization_id, :kind, :occurred_at])
    |> validate_inclusion(:kind, @kinds)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource, name: :change_events_tenant_resource_fkey)
    |> assoc_constraint(:source, name: :change_events_tenant_source_fkey)
    |> assoc_constraint(:sync_run, name: :change_events_tenant_sync_run_fkey)
    |> assoc_constraint(:observation, name: :change_events_tenant_observation_fkey)
  end

  @doc false
  def audit_value(nil), do: nil
  def audit_value(%Postgrex.MACADDR{address: address}), do: %{"value" => format_mac(address)}
  def audit_value(%Postgrex.INET{} = address), do: %{"value" => format_inet(address)}
  def audit_value(value) when is_map(value), do: value

  def audit_value(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: %{"value" => value}

  def audit_value(value), do: %{"value" => inspect(value)}

  defp format_mac(address) do
    address
    |> Tuple.to_list()
    |> Enum.map_join(":", &(Integer.to_string(&1, 16) |> String.pad_leading(2, "0")))
  end

  defp format_inet(%Postgrex.INET{address: address, netmask: nil}) do
    address |> :inet.ntoa() |> to_string()
  end

  defp format_inet(%Postgrex.INET{address: address, netmask: netmask}) do
    "#{:inet.ntoa(address)}/#{netmask}"
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value
end
