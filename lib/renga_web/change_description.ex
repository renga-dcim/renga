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
  defp noun(field), do: String.replace(field, "_", " ")

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

  defp rule_label(%{metadata: %{"rule_name" => name}}), do: "the rule #{name}"
  defp rule_label(_event), do: "a triage rule"

  defp with_field(verb, nil), do: verb
  defp with_field(verb, field), do: "#{verb} #{String.replace(field, "_", " ")}"
end
