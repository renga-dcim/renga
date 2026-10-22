defmodule RengaWeb.ChangeDescription do
  @moduledoc """
  Reads a change event as a short sentence ("Owner set to Platform by the
  rule Web fleet"), so the Activity feed and a resource's own history
  describe the same change the same way.
  """

  # Field names come from the reconciler (for example "lifecycle_state"); they
  # read as words so a change reads as a sentence.
  @doc "The change as a sentence, starting with a capital letter."
  def describe(%{kind: "created", field: field, new_value: %{"value" => value}})
      when is_binary(field),
      do: "Created #{noun(field)} #{value}"

  def describe(%{kind: "created"}), do: "Created"

  def describe(%{kind: "deleted", field: field, old_value: %{"value" => value}})
      when is_binary(field),
      do: "Deleted #{noun(field)} #{value}"

  def describe(%{kind: "deleted"}), do: "Deleted"
  def describe(%{kind: "discovered"}), do: "Discovered"
  def describe(%{kind: "stale"}), do: "Marked stale"

  def describe(%{kind: "withdrawn", old_value: %{"target" => target}}) when is_binary(target),
    do: "No longer reported by #{target}"

  # A managed address's assignment names its interface.
  def describe(%{kind: "updated", field: "assignment", new_value: %{"value" => interface}})
      when is_binary(interface),
      do: "Assigned to #{interface}"

  def describe(%{kind: "updated", field: "assignment", old_value: %{"value" => interface}})
      when is_binary(interface),
      do: "Unassigned from #{interface}"

  # RFD 10: an operator's allocated draw for one power port.
  def describe(%{kind: "updated", field: "power_allocation", new_value: %{} = new}),
    do: "Allocated #{new["value"]} W to power port #{new["port"]}"

  def describe(%{kind: "updated", field: "power_allocation", old_value: %{} = old}),
    do: "Cleared the allocated draw of power port #{old["port"]}"

  # RFD 10: a power port's power factor override, and the organization default.
  def describe(%{kind: "updated", field: "power_factor", new_value: %{} = new}),
    do: "Set the power factor of power port #{new["port"]} to #{new["value"]}"

  def describe(%{kind: "updated", field: "power_factor", old_value: %{} = old}),
    do: "Cleared the power factor of power port #{old["port"]}"

  def describe(%{kind: "updated", field: "default_power_factor", new_value: %{"value" => value}}),
    do: "Set the organization's default power factor to #{value}"

  def describe(%{kind: "updated", field: "default_power_factor"}),
    do: "Cleared the organization's default power factor"

  def describe(%{
        kind: "updated",
        field: "installation_key",
        metadata: %{"status" => "approved"},
        new_value: %{"value" => fingerprint}
      }),
      do: "Approved installation key #{fingerprint}"

  def describe(%{
        kind: "updated",
        field: "installation_key",
        new_value: %{"value" => fingerprint}
      }),
      do: "Presented a new installation key #{fingerprint}"

  def describe(%{
        kind: "updated",
        field: "target_binding",
        new_value: %{"value" => installation, "fingerprint" => fingerprint}
      }),
      do: "Bound privileged jobs to #{installation} (key #{fingerprint})"

  def describe(%{
        kind: "updated",
        field: "target_binding",
        old_value: %{"value" => installation}
      }),
      do: "Unbound privileged jobs from #{installation}"

  def describe(%{kind: "updated", field: field}), do: with_field("Updated", field)
  def describe(%{kind: "conflict", field: field}), do: with_field("Conflict on", field)

  def describe(%{kind: "manual_override", field: field}),
    do: with_field("Override set on", field)

  def describe(%{kind: "override_removed", field: field}),
    do: with_field("Override removed from", field)

  def describe(%{kind: "finding_assigned", new_value: nil, field: field}),
    do: "Unassigned #{finding_label(field)}"

  def describe(%{kind: "finding_assigned", new_value: %{"assignee" => assignee}, field: field}),
    do: "Assigned #{finding_label(field)} to #{assignee}"

  def describe(%{kind: "finding_snoozed", new_value: nil, field: field}),
    do: "Woke #{finding_label(field)}"

  def describe(%{kind: "finding_snoozed", new_value: %{"snoozed_until" => until}, field: field}),
    do: "Snoozed #{finding_label(field)} until #{format_iso(until)}"

  def describe(%{kind: "finding_exception", field: field}),
    do: "Accepted #{finding_label(field)} as an exception"

  def describe(%{kind: "finding_exception_removed", field: field}),
    do: "Removed the exception on #{finding_label(field)}"

  def describe(%{kind: "owner_changed", new_value: %{"name" => name}}),
    do: "Owner set to #{name}"

  def describe(%{kind: "owner_changed"}), do: "Owner removed"

  def describe(%{kind: "rule_applied", field: "placement", new_value: value} = event),
    do: "Placed at #{value["value"]} by #{rule_label(event)}"

  def describe(%{kind: "rule_applied", new_value: value} = event),
    do: "Owner set to #{value["name"]} by #{rule_label(event)}"

  def describe(%{kind: "member_role_changed", metadata: metadata, new_value: %{"value" => role}}),
    do: "#{metadata["member"]} became #{role}" <> reason(metadata)

  def describe(%{kind: "member_disabled", metadata: metadata}),
    do: "#{metadata["member"]} disabled" <> reason(metadata)

  def describe(%{kind: "member_enabled", metadata: metadata}),
    do: "#{metadata["member"]} re-enabled" <> reason(metadata)

  def describe(%{kind: "member_invited", metadata: metadata, new_value: %{"value" => role}}),
    do: "Invited #{metadata["member"]} as #{role}"

  def describe(%{kind: "invitation_revoked", metadata: metadata}),
    do: "Revoked the invitation for #{metadata["member"]}"

  def describe(%{kind: "member_joined", metadata: metadata, new_value: %{"value" => role}}),
    do: "#{metadata["member"]} joined as #{role}"

  def describe(%{kind: "team_member_added", metadata: metadata, new_value: %{"name" => team}}),
    do: "Added #{metadata["member"]} to #{team}"

  def describe(%{kind: "team_member_removed", metadata: metadata, new_value: %{"name" => team}}),
    do: "Removed #{metadata["member"]} from #{team}"

  def describe(%{kind: "capability_allowed", metadata: %{"title" => title}}),
    do: "Enabled #{title}"

  def describe(%{kind: "capability_disallowed", metadata: %{"title" => title}}),
    do: "Disabled #{title}"

  def describe(%{kind: "role_created", new_value: %{"name" => name}}),
    do: "Defined the #{name} role"

  def describe(%{kind: "role_updated", old_value: %{"name" => old}, new_value: %{"name" => new}})
      when old != new,
      do: "Renamed the #{old} role to #{new}"

  def describe(%{kind: "role_updated", new_value: %{"name" => name}}),
    do: "Changed the #{name} role's permissions"

  def describe(%{kind: "role_deleted", old_value: %{"name" => name}}),
    do: "Deleted the #{name} role"

  def describe(%{kind: "role_assigned", metadata: metadata, new_value: %{"value" => role}}),
    do: "Gave #{metadata["member"]} the #{role} role"

  def describe(%{kind: "role_unassigned", metadata: metadata, old_value: %{"value" => role}}),
    do: "Took the #{role} role from #{metadata["member"]}"

  def describe(%{kind: "role_expired", metadata: metadata, old_value: %{"value" => role}}),
    do: "The #{role} role expired for #{metadata["member"]}"

  def describe(%{kind: "organization_created"}), do: "Created this organization"

  def describe(%{
        kind: "organization_domain_changed",
        metadata: %{"change" => change} = metadata
      }),
      do: organization_domain_change(change, metadata["domain"])

  def describe(%{kind: "identity_provider_changed", metadata: %{"change" => change} = metadata}),
    do: identity_provider_change(change, metadata["name"] || metadata["provider"], metadata)

  def describe(%{
        kind: "security_setting_changed",
        field: "require_mfa",
        new_value: new_value,
        metadata: metadata
      }) do
    change =
      if new_value == %{"value" => true},
        do: "Required multi-factor authentication for members",
        else: "Stopped requiring multi-factor authentication"

    change <> reason(metadata)
  end

  def describe(%{kind: "security_setting_changed", field: field, metadata: metadata}),
    do: "Changed the #{String.replace(field, "_", " ")} security setting" <> reason(metadata)

  def describe(%{kind: "limit_set", field: field}),
    do: "Changed the #{String.replace(field, "_", " ")} limit"

  def describe(%{kind: "limit_cleared", field: field}),
    do: "Returned the #{String.replace(field, "_", " ")} limit to the deployment default"

  def describe(%{kind: "scim_connection_created", metadata: %{"provider_id" => provider}}),
    do: "Connected SCIM provisioning through #{provider}"

  def describe(%{kind: "scim_connection_disabled", metadata: %{"provider_id" => provider}}),
    do: "Disabled SCIM provisioning through #{provider}"

  def describe(%{kind: "scim_connection_enabled", metadata: %{"provider_id" => provider}}),
    do: "Re-enabled SCIM provisioning through #{provider}"

  def describe(%{kind: "scim_default_role_changed", new_value: %{"value" => role}}),
    do: "Set the SCIM default role to #{role}"

  def describe(%{kind: "scim_default_role_changed"}),
    do: "Removed the SCIM default role"

  def describe(%{kind: "scim_token_created", metadata: %{"token" => name}}),
    do: "Issued the SCIM token #{name}"

  def describe(%{kind: "scim_token_revoked", metadata: %{"token" => name}}),
    do: "Revoked the SCIM token #{name}"

  def describe(%{kind: "scim_user_created", metadata: %{"user_name" => name}}),
    do: "SCIM provisioned #{name}"

  def describe(%{kind: "scim_user_updated", metadata: %{"user_name" => name}}),
    do: "SCIM updated #{name}"

  def describe(%{kind: "scim_user_deleted", metadata: %{"user_name" => name}}),
    do: "SCIM removed #{name}"

  def describe(%{kind: "scim_group_created", metadata: %{"group" => name}}),
    do: "SCIM created the group #{name}"

  def describe(%{kind: "scim_group_updated", metadata: %{"group" => name}}),
    do: "SCIM updated the group #{name}"

  def describe(%{kind: "scim_group_deleted", metadata: %{"group" => name}}),
    do: "SCIM deleted the group #{name}"

  def describe(%{kind: "scim_user_linked", metadata: %{"user_name" => name}}),
    do: "Linked the SCIM user #{name} at sign-in"

  def describe(%{kind: "scim_link_refused", metadata: %{"user_name" => name}}),
    do: "Refused to relink the SCIM user #{name} to another sign-in"

  def describe(%{
        kind: "scim_group_mapped",
        metadata: %{"group" => group},
        new_value: %{"value" => role}
      }),
      do: "Mapped the SCIM group #{group} to the #{role} role"

  def describe(%{kind: "scim_group_mapped", metadata: %{"group" => group}}),
    do: "Unmapped the SCIM group #{group}"

  def describe(%{kind: "scim_grant_added", metadata: metadata, new_value: %{"value" => role}}),
    do: "SCIM gave #{metadata["member"]} the #{role} role"

  def describe(%{
        kind: "scim_grant_changed",
        metadata: metadata,
        old_value: %{"value" => old},
        new_value: %{"value" => new}
      }),
      do: "SCIM changed #{metadata["member"]} from #{old} to #{new}"

  def describe(%{kind: "scim_grant_removed", metadata: metadata}),
    do: "SCIM removed #{metadata["member"]}'s access"

  # Job events read as "Inventory collection failed"; the job itself keeps
  # the full history.
  def describe(%{kind: "job_requested", metadata: metadata}),
    do: "#{job_noun(metadata)} requested"

  def describe(%{kind: "job_outcome", metadata: %{"state" => state} = metadata}) do
    noun = job_noun(metadata)

    case state do
      "uncertain" -> "#{noun} needs review"
      state when state in ~w(succeeded failed cancelled expired) -> "#{noun} #{state}"
      _other -> "#{noun} ended"
    end
  end

  def describe(%{kind: "request_" <> action} = event) do
    verb =
      case action do
        "created" -> "Requested"
        "approved" -> "Approved request:"
        "rejected" -> "Rejected request:"
        "withdrawn" -> "Withdrew request:"
      end

    "#{verb} #{request_change(event)}"
  end

  def describe(%{kind: kind}), do: String.capitalize(String.replace(kind, "_", " "))

  # What a created or deleted record is; acronyms keep their capitals.
  defp noun("vrf"), do: "VRF"
  defp noun("ip_address"), do: "IP address"
  defp noun(field), do: String.replace(field, "_", " ")

  defp request_change(%{field: "adoption", new_value: %{"address" => address}}),
    do: "adoption of #{address}"

  defp request_change(%{field: field, new_value: %{"value" => value}}) do
    property =
      field |> to_string() |> String.replace_prefix("host.", "") |> String.replace("_", " ")

    "#{property} → #{value}"
  end

  # Finding events name the finding as "domain.kind"; the kind reads best.
  defp finding_label(field) do
    field |> to_string() |> String.split(".") |> List.last() |> String.replace("_", " ")
  end

  defp format_iso(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
      _invalid -> iso
    end
  end

  defp job_noun(%{"noun" => noun}) when is_binary(noun), do: noun
  defp job_noun(_metadata), do: "Job"

  defp rule_label(%{metadata: %{"rule_name" => name}}), do: "the rule #{name}"
  defp rule_label(_event), do: "a triage rule"

  defp with_field(verb, nil), do: verb
  defp with_field(verb, field), do: "#{verb} #{String.replace(field, "_", " ")}"

  defp reason(%{"reason" => reason}) when is_binary(reason), do: " · #{reason}"
  defp reason(_metadata), do: ""

  defp organization_domain_change("added", domain),
    do: "Claimed the email domain #{domain}, waiting for its DNS record"

  defp organization_domain_change("verified", domain),
    do: "Verified the email domain #{domain} for sign-in"

  defp organization_domain_change("unverified", domain),
    do: "The email domain #{domain} stopped routing sign-in: its DNS record is gone"

  defp organization_domain_change("removed", domain), do: "Removed the email domain #{domain}"
  defp organization_domain_change(_change, domain), do: "Changed the email domain #{domain}"

  defp identity_provider_change("created", name, _metadata),
    do: "Added the identity provider #{name}, waiting for a test sign-in"

  defp identity_provider_change("updated", name, %{"changed" => changed}) when is_list(changed) do
    if "display_name" in changed,
      do: "Renamed the identity provider to #{name}",
      else: "Changed how the identity provider #{name} is shown"
  end

  defp identity_provider_change("revision_pending", name, %{"changed" => [_ | _] = changed}),
    do: "Proposed new settings for #{name} (#{Enum.map_join(changed, ", ", &humanize/1)})"

  defp identity_provider_change("revision_pending", name, _metadata),
    do: "Proposed new settings for #{name}"

  defp identity_provider_change("revision_discarded", name, _metadata),
    do: "Discarded the proposed settings for #{name}"

  defp identity_provider_change("activated", name, %{"revision" => revision}),
    do: "A test sign-in activated settings #{revision} of #{name}"

  defp identity_provider_change("enabled", name, _metadata), do: "Turned on sign-in with #{name}"

  defp identity_provider_change("disabled", name, _metadata),
    do: "Turned off sign-in with #{name}"

  defp identity_provider_change("removed", name, _metadata),
    do: "Removed the identity provider #{name}"

  defp identity_provider_change(_change, name, _metadata),
    do: "Changed the identity provider #{name}"

  defp humanize("client_secret"), do: "client secret"
  defp humanize("client_id"), do: "client ID"
  defp humanize("allow_sign_up"), do: "sign-up"
  defp humanize("session_lifetime_seconds"), do: "session lifetime"
  defp humanize(field), do: String.replace(field, "_", " ")
end
