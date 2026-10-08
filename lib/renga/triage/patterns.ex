defmodule Renga.Triage.Patterns do
  @moduledoc """
  Groups resources in triage by a signal they share, so an onboarding burst
  reads as a few patterns rather than hundreds of rows (RFD 8, "Triage").

  Each pattern names the fact its members lack and suggests the rule that
  would fill it from that shared signal:

    * resources missing a placement that report from the same /24 (or /64),
      or through the same intake key, suggest a network location rule;
    * resources missing a placement whose LLDP neighbor switch sits in a rack
      suggest a top of rack rule;
    * resources missing an owner whose hostnames share a prefix, or whose
      collectors send the same label, suggest an ownership rule.

  Suggestions are rule form attributes, not rules: a person picks the site
  or team and sees the rule's preview before anything changes. Patterns are
  computed on each request, like triage itself.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.Address
  alias Renga.Inventory.Host
  alias Renga.Inventory.IntakeApiKey
  alias Renga.Inventory.Resource
  alias Renga.Repo
  alias Renga.Triage
  alias Renga.TriageRules

  # Loopback and link-local addresses say nothing about where a host is.
  defmacrop routable(address) do
    quote do
      not fragment(
        "host(?)::inet <<= ANY('{127.0.0.0/8,169.254.0.0/16,::1/128,fe80::/10}'::inet[])",
        unquote(address)
      )
    end
  end

  # The /24 (IPv4) or /64 (IPv6) an address sits in, as text.
  defmacrop network(address) do
    quote do
      fragment(
        "host(network(set_masklen(host(?)::inet, CASE WHEN family(?) = 4 THEN 24 ELSE 64 END))) || CASE WHEN family(?) = 4 THEN '/24' ELSE '/64' END",
        unquote(address),
        unquote(address),
        unquote(address)
      )
    end
  end

  # A pattern needs at least this many resources; one resource is just a row.
  @min_size 2
  @per_kind 5
  @examples 3

  @doc """
  Patterns among resources in triage, largest first. Each is a map with
  `:id`, `:kind`, `:fact`, `:label`, `:count`, `:examples` (resource names),
  and `:suggestion` (attributes for the rule form).

  Options: `:fact` limits patterns to those filling one fact.
  """
  def list(%Scope{} = scope, opts \\ []) do
    fact = Keyword.get(opts, :fact)

    [
      {:placement, &subnets/1},
      {:placement, &intake_keys/1},
      {:placement, &top_of_rack/1},
      {:owner, &hostname_prefixes/1},
      {:owner, &labels/1}
    ]
    |> Enum.filter(fn {pattern_fact, _finder} -> fact in [nil, pattern_fact] end)
    |> Enum.flat_map(fn {_fact, finder} -> finder.(scope) end)
    |> Enum.sort_by(&{-&1.count, &1.label})
  end

  ## Placement

  defp subnets(%Scope{organization_id: organization_id} = scope) do
    unplaced = Triage.missing_ids_query(scope, :placement)

    addresses =
      from address in Address,
        join: resource in Resource,
        on: resource.id == address.resource_id,
        where: address.organization_id == ^organization_id,
        where: address.resource_id in subquery(unplaced),
        where: routable(address.address),
        select: %{
          resource_id: address.resource_id,
          name: resource.name,
          key: network(address.address)
        }

    reported =
      from report in subquery(TriageRules.latest_reports(organization_id)),
        join: resource in Resource,
        on: resource.id == report.resource_id,
        where: report.resource_id in subquery(unplaced),
        where: not is_nil(report.reported_from),
        where: routable(report.reported_from),
        select: %{
          resource_id: report.resource_id,
          name: resource.name,
          key: network(report.reported_from)
        }

    addresses
    |> union(^reported)
    |> grouped()
    |> Enum.map(fn %{key: subnet} = group ->
      pattern(group, "subnet-#{subnet}", :network_location, :placement,
        label: "Report from #{subnet}",
        suggestion: %{
          "kind" => "network_location",
          "match_on" => "subnet",
          "subnet" => subnet,
          "name" => "Subnet #{subnet}"
        }
      )
    end)
  end

  defp intake_keys(%Scope{organization_id: organization_id} = scope) do
    unplaced = Triage.missing_ids_query(scope, :placement)

    keys =
      from report in subquery(TriageRules.latest_reports(organization_id)),
        join: resource in Resource,
        on: resource.id == report.resource_id,
        join: key in IntakeApiKey,
        on: key.id == report.intake_api_key_id and key.organization_id == ^organization_id,
        where: report.resource_id in subquery(unplaced),
        select: %{
          resource_id: report.resource_id,
          name: resource.name,
          key: fragment("? || ':' || ?", type(key.id, :string), key.name)
        }

    keys
    |> grouped()
    |> Enum.map(fn %{key: key} = group ->
      [id, name] = String.split(key, ":", parts: 2)

      pattern(group, "intake-key-#{id}", :network_location, :placement,
        label: "Report through #{name}",
        suggestion: %{
          "kind" => "network_location",
          "match_on" => "intake_key",
          "intake_api_key_id" => id,
          "name" => "Intake key #{name}"
        }
      )
    end)
  end

  # One pattern for every unplaced resource a top of rack rule would place,
  # offered until the organization has such a rule.
  defp top_of_rack(scope) do
    suggestion = %{"kind" => "top_of_rack", "name" => "Top of rack"}

    with false <- Enum.any?(TriageRules.list_rules(scope), &(&1.kind == "top_of_rack")),
         {:ok, %{will_set: count, examples: examples}} when count >= @min_size <-
           TriageRules.preview(scope, suggestion) do
      [
        %{
          id: "top-of-rack",
          kind: :top_of_rack,
          fact: :placement,
          label: "LLDP neighbor switch in a rack",
          count: count,
          examples: examples |> Enum.map(& &1.name) |> Enum.take(@examples),
          suggestion: suggestion
        }
      ]
    else
      _none -> []
    end
  end

  ## Owner

  # The leading letters of a hostname and the separator after them, so
  # web-01, web-02, and web-17 share "web-".
  defp hostname_prefixes(%Scope{organization_id: organization_id} = scope) do
    unowned = Triage.missing_ids_query(scope, :owner)

    prefixes =
      from host in Host,
        join: resource in Resource,
        on: resource.id == host.resource_id,
        where: host.organization_id == ^organization_id,
        where: host.resource_id in subquery(unowned),
        where: fragment("? ~ '^[a-z]{2,}[-_.]\\?'", host.hostname),
        select: %{
          resource_id: host.resource_id,
          name: resource.name,
          key: fragment("substring(? from '^[a-z]{2,}[-_.]\\?')", host.hostname)
        }

    prefixes
    |> grouped()
    |> Enum.map(fn %{key: prefix} = group ->
      pattern(group, "hostname-#{prefix}", :ownership, :owner,
        label: "Hostname #{prefix}*",
        suggestion: %{
          "kind" => "ownership",
          "match_on" => "hostname",
          "hostname_pattern" => "#{prefix}*",
          "name" => "Hostnames #{prefix}*"
        }
      )
    end)
  end

  defp labels(%Scope{organization_id: organization_id} = scope) do
    unowned = Triage.missing_ids_query(scope, :owner)

    labels =
      from report in subquery(TriageRules.latest_reports(organization_id)),
        join: resource in Resource,
        on: resource.id == report.resource_id,
        join:
          label in fragment(
            "jsonb_each_text(CASE WHEN jsonb_typeof(?->'resources'->0->'labels') = 'object' THEN ?->'resources'->0->'labels' ELSE '{}'::jsonb END)",
            report.payload,
            report.payload
          ),
        on: true,
        where: report.resource_id in subquery(unowned),
        select: %{
          resource_id: report.resource_id,
          name: resource.name,
          key: fragment("? || '=' || ?", label.key, label.value)
        }

    labels
    |> grouped()
    |> Enum.map(fn %{key: label} = group ->
      [key, value] = String.split(label, "=", parts: 2)

      pattern(group, "label-#{label}", :ownership, :owner,
        label: "Label #{label}",
        suggestion: %{
          "kind" => "ownership",
          "match_on" => "label",
          "label_key" => key,
          "label_value" => value,
          "name" => "Label #{label}"
        }
      )
    end)
  end

  ## Helpers

  # Groups signal rows (`resource_id`, `name`, `key`) by key, counting each
  # resource once, with a few example names.
  defp grouped(rows) do
    from(row in subquery(rows),
      group_by: row.key,
      having: count(row.resource_id, :distinct) >= @min_size,
      order_by: [desc: count(row.resource_id, :distinct), asc: row.key],
      limit: @per_kind,
      select: %{
        key: row.key,
        count: count(row.resource_id, :distinct),
        examples:
          fragment("(array_agg(DISTINCT ? ORDER BY ?))[1:?]", row.name, row.name, @examples)
      }
    )
    |> Repo.all()
  end

  defp pattern(group, id, kind, fact, opts) do
    %{
      id: id,
      kind: kind,
      fact: fact,
      label: Keyword.fetch!(opts, :label),
      count: group.count,
      examples: group.examples,
      suggestion: Keyword.fetch!(opts, :suggestion)
    }
  end
end
