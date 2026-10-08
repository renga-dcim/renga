defmodule Renga.Inventory.SourcePrecedence do
  @moduledoc """
  Which kind of source is trusted most for a projected field, and why.

  The reconciler uses `priority/2` to decide which report owns a field;
  field provenance uses the same function and `explain/2` to tell people
  why a value won. Keeping both here means the explanation cannot drift from
  the rule. A manual override always wins.
  """

  @doc "Higher wins. Equal priorities fall back to the most recent report."
  def priority("manual", _path), do: 500
  def priority("bmc", "host." <> field) when field in ~w(vendor model asset_tag), do: 400
  def priority("switch_poller", "interfaces." <> _rest), do: 400
  def priority("host_agent", _path), do: 300
  def priority("vm_provider", _path), do: 200
  def priority("bmc", _path), do: 100
  def priority(_kind, _path), do: 0

  @doc "Why a source of this kind is trusted for this field, as a sentence."
  def explain("manual", _path), do: "Overrides set by people always win."

  def explain("bmc", "host." <> field) when field in ~w(vendor model asset_tag),
    do: "Management controllers are trusted most for vendor, model, and asset tag."

  def explain("switch_poller", "interfaces." <> _rest),
    do: "Switch pollers are trusted most for interfaces."

  def explain("host_agent", _path),
    do: "Host agents are trusted over virtualization providers and management controllers."

  def explain("vm_provider", _path),
    do: "Virtualization providers are trusted over management controllers for this field."

  def explain(_kind, _path), do: "No more trusted source reports this field."

  @doc "A short name for a kind of source."
  def kind_label("host_agent"), do: "host agent"
  def kind_label("bmc"), do: "management controller"
  def kind_label("switch_poller"), do: "switch poller"
  def kind_label("vm_provider"), do: "virtualization provider"
  def kind_label("manual"), do: "override"
  def kind_label(kind) when is_binary(kind), do: String.replace(kind, "_", " ")
end
