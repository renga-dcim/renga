defmodule Renga.Power do
  @moduledoc """
  Power inventory (RFD 10): the panels at a site and the feeds they supply,
  and the power ports and outlets on devices.

  Nothing on the network knows a building's electrical layout, so panels and
  feeds are always entered. Each has a resource envelope created with its
  typed row in one transaction, like the other DCIM objects. Owners and
  admins change them; everyone in the organization reads them.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.DCIM.Location
  alias Renga.DCIM.Rack
  alias Renga.DCIM.Site
  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Inventory.ResourceStore
  alias Renga.Power.Capacity
  alias Renga.Power.Feed
  alias Renga.Power.Outlet
  alias Renga.Power.Panel
  alias Renga.Power.Port
  alias Renga.Repo

  @display_name_limit 255
  @feed_label_separator " / "

  @doc """
  Lists a site's panels by name, each with its location and its feeds by
  name with their racks.
  """
  def list_panels(%Scope{organization_id: organization_id}, site_id) do
    feeds =
      from(feed in Feed, order_by: [asc: feed.name, asc: feed.id], preload: [rack: :resource])

    Panel
    |> where([panel], panel.organization_id == ^organization_id and panel.site_id == ^site_id)
    |> order_by([panel], asc: panel.name, asc: panel.id)
    |> preload([:resource, location: :resource, feeds: ^feeds])
    |> Repo.all()
  end

  @doc "Lists the feeds assigned to a rack, by panel and name."
  def list_rack_feeds(%Scope{organization_id: organization_id}, rack_id) do
    Feed
    |> join(:inner, [feed], panel in assoc(feed, :panel))
    |> where([feed], feed.organization_id == ^organization_id and feed.rack_id == ^rack_id)
    |> order_by([feed, panel], asc: panel.name, asc: feed.name, asc: feed.id)
    |> preload([_feed, panel], panel: panel)
    |> Repo.all()
  end

  def get_panel!(%Scope{organization_id: organization_id}, id) do
    Panel
    |> where([panel], panel.organization_id == ^organization_id)
    |> preload([:resource, :site, location: :resource])
    |> Repo.get!(id)
  end

  def get_feed!(%Scope{organization_id: organization_id}, id) do
    Feed
    |> where([feed], feed.organization_id == ^organization_id)
    |> preload([:resource, :panel, rack: :resource])
    |> Repo.get!(id)
  end

  @doc """
  Usable capacity totals of the given feeds, one per unit: AC feeds in VA
  and DC feeds in W, never added together. Units with no feeds are absent.
  """
  def capacity_totals(feeds) do
    feeds
    |> Enum.map(&Capacity.of/1)
    |> Enum.group_by(& &1.unit)
    |> Map.new(fn {unit, capacities} ->
      {unit, Enum.reduce(capacities, Decimal.new(0), &Decimal.add(&1.usable, &2))}
    end)
  end

  @doc """
  Creates a panel at a site, optionally inside one of the site's locations.
  """
  def create_panel(%Scope{} = scope, attrs) do
    power_transaction(scope, fn ->
      validation = Panel.changeset(%Panel{organization_id: scope.organization_id}, attrs)
      reject_invalid!(validation, [:resource_id])
      site_id = Ecto.Changeset.get_field(validation, :site_id)
      location_id = Ecto.Changeset.get_field(validation, :location_id)
      scoped_get!(Site, scope.organization_id, site_id)
      if location_id, do: validate_location!(scope, location_id, site_id)

      name = Ecto.Changeset.get_field(validation, :name)
      resource = insert_envelope!(scope, "power_panel", name)

      panel =
        %Panel{organization_id: scope.organization_id, resource_id: resource.id}
        |> Panel.changeset(attrs)
        |> insert_or_rollback()

      record_event!(scope, resource, "created", "power_panel", nil, name)
      %{panel | resource: resource}
    end)
  end

  @doc "Renames a panel or moves it to another location at its site."
  def update_panel(%Scope{} = scope, %Panel{id: id}, attrs) do
    power_transaction(scope, fn ->
      stored = lock!(Panel, scope.organization_id, id)
      # A panel's feeds and their racks are at its site, so it never moves.
      attrs = Map.drop(attrs, [:site_id, "site_id"])
      changeset = Panel.changeset(stored, attrs)
      location_id = Ecto.Changeset.get_field(changeset, :location_id)
      if location_id, do: validate_location!(scope, location_id, stored.site_id)
      panel = update_or_rollback(changeset)

      if panel.name != stored.name do
        rename_envelope!(scope, panel.resource_id, panel.name)
        record_event!(scope, %{id: panel.resource_id}, "updated", "name", stored.name, panel.name)

        # Feed envelopes are labelled with their panel's name.
        Feed
        |> where([feed], feed.organization_id == ^scope.organization_id)
        |> where([feed], feed.panel_id == ^panel.id)
        |> Repo.all()
        |> Enum.each(&rename_envelope!(scope, &1.resource_id, feed_label(panel, &1)))
      end

      Repo.preload(panel, [:resource, location: :resource], force: true)
    end)
  end

  @doc """
  Adds a feed to a panel. The feed belongs to the panel's site, and its rack,
  when given, must be at that site.
  """
  def create_feed(%Scope{} = scope, panel_id, attrs) do
    power_transaction(scope, fn ->
      panel = lock!(Panel, scope.organization_id, panel_id)

      new_feed = %Feed{
        organization_id: scope.organization_id,
        site_id: panel.site_id,
        panel_id: panel.id
      }

      validation = Feed.changeset(new_feed, attrs)
      reject_invalid!(validation, [:resource_id])
      rack_id = Ecto.Changeset.get_field(validation, :rack_id)
      if rack_id, do: validate_rack!(scope, rack_id, panel.site_id)

      name = Ecto.Changeset.get_field(validation, :name)
      resource = insert_envelope!(scope, "power_feed", feed_label(panel, name))

      feed =
        %{new_feed | resource_id: resource.id}
        |> Feed.changeset(attrs)
        |> insert_or_rollback()

      record_event!(scope, resource, "created", "power_feed", nil, name)
      Repo.preload(%{feed | resource: resource}, [:panel, rack: :resource])
    end)
  end

  @doc """
  Changes a feed's electrical ratings, side, status, or rack. Every changed
  field is recorded on the feed's activity.
  """
  def update_feed(%Scope{} = scope, %Feed{id: id}, attrs) do
    power_transaction(scope, fn ->
      stored = lock!(Feed, scope.organization_id, id)
      changeset = Feed.changeset(stored, attrs)
      rack_id = Ecto.Changeset.get_change(changeset, :rack_id)
      if rack_id, do: validate_rack!(scope, rack_id, stored.site_id)
      feed = update_or_rollback(changeset)

      for {field, new_value} <- changeset.changes, field != :metadata do
        record_event!(
          scope,
          %{id: feed.resource_id},
          "updated",
          Atom.to_string(field),
          Map.get(stored, field),
          new_value
        )
      end

      if feed.name != stored.name do
        panel = scoped_get!(Panel, scope.organization_id, feed.panel_id)
        rename_envelope!(scope, feed.resource_id, feed_label(panel, feed))
      end

      Repo.preload(feed, [:resource, :panel, rack: :resource], force: true)
    end)
  end

  @doc """
  A device's power ports and outlets by name, each outlet with its inlet.
  They come from the device's hardware type (RFD 10 phase 2); retired
  endpoints, which only cable history still names, are left out.
  """
  def list_device_endpoints(%Scope{organization_id: organization_id}, resource_id) do
    by_name = fn schema ->
      schema
      |> where([row], row.organization_id == ^organization_id and row.resource_id == ^resource_id)
      |> where([row], is_nil(row.retired_at))
      |> order_by([row], fragment(~s(? COLLATE "C"), row.name))
    end

    %{
      ports: Repo.all(by_name.(Port)),
      outlets: Outlet |> by_name.() |> preload(:inlet_port) |> Repo.all()
    }
  end

  @doc """
  Sets or clears (`nil`) a port's allocated draw override, recorded on its
  device's activity.
  """
  def update_port_allocation(%Scope{} = scope, %Port{id: id}, attrs) do
    power_transaction(scope, fn ->
      stored = lock!(Port, scope.organization_id, id)
      changeset = Port.allocation_changeset(stored, attrs)
      port = update_or_rollback(changeset)

      if Map.has_key?(changeset.changes, :allocated_draw_w) do
        {:ok, _event} =
          Inventory.create_change_event(scope, %{
            kind: "updated",
            field: "power_allocation",
            resource_id: port.resource_id,
            old_value: allocation_value(port, stored.allocated_draw_w),
            new_value: allocation_value(port, port.allocated_draw_w)
          })
      end

      port
    end)
  end

  defp allocation_value(_port, nil), do: nil
  defp allocation_value(port, watts), do: %{"port" => port.name, "value" => watts}

  def change_port_allocation(%Port{} = port, attrs \\ %{}),
    do: Port.allocation_changeset(port, attrs)

  def change_panel(%Panel{} = panel, attrs \\ %{}), do: Panel.changeset(panel, attrs)
  def change_feed(%Feed{} = feed, attrs \\ %{}), do: Feed.changeset(feed, attrs)

  # Panels, feeds, and the ports' planning values are DCIM objects, so their
  # changes need RFD 17's `dcim.edit`, like sites and racks.
  defp power_transaction(scope, mutation) do
    scope
    |> Inventory.organization_management_transaction("dcim.edit", mutation)
    |> Changes.broadcast(scope.organization_id)
  end

  # The envelope does not exist while the typed row is validated, so its
  # absence is the one error expected; anything else is the caller's input.
  defp reject_invalid!(changeset, expected_missing) do
    case Keyword.drop(changeset.errors, expected_missing) do
      [] -> :ok
      errors -> Repo.rollback(%{changeset | errors: errors, action: :insert})
    end
  end

  defp insert_envelope!(scope, kind, display_name) do
    case ResourceStore.insert(scope.organization_id, %{
           kind: kind,
           name: "#{String.replace(kind, "_", "-")}-#{Ecto.UUID.generate()}",
           display_name: display_name,
           lifecycle_state: "active"
         }) do
      {:ok, resource} -> resource
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # A feed's envelope keeps both names identifiable without exceeding the
  # resource display-name limit; the typed rows retain the complete names.
  defp feed_label(%Panel{name: panel_name}, %Feed{name: name}), do: feed_label(panel_name, name)
  defp feed_label(%Panel{name: panel_name}, name), do: feed_label(panel_name, name)

  defp feed_label(panel_name, name) do
    available = @display_name_limit - codepoint_length(@feed_label_separator)
    half = div(available, 2)
    panel_length = codepoint_length(panel_name)
    name_length = codepoint_length(name)

    {panel_limit, name_limit} =
      cond do
        panel_length + name_length <= available ->
          {panel_length, name_length}

        panel_length <= half ->
          {panel_length, available - panel_length}

        name_length <= half ->
          {available - name_length, name_length}

        true ->
          {half, available - half}
      end

    truncate_label_part(panel_name, panel_limit) <>
      @feed_label_separator <> truncate_label_part(name, name_limit)
  end

  defp truncate_label_part(value, limit) do
    if codepoint_length(value) <= limit do
      value
    else
      {graphemes, _length} =
        value
        |> String.graphemes()
        |> Enum.reduce_while({[], 0}, &take_grapheme(&1, &2, limit))

      graphemes |> Enum.reverse() |> Enum.join() |> Kernel.<>("…")
    end
  end

  # Keeps graphemes while they leave room for the ellipsis.
  defp take_grapheme(grapheme, {graphemes, length}, limit) do
    next_length = length + codepoint_length(grapheme)

    if next_length < limit,
      do: {:cont, {[grapheme | graphemes], next_length}},
      else: {:halt, {graphemes, length}}
  end

  defp codepoint_length(value), do: value |> String.codepoints() |> length()

  defp rename_envelope!(scope, resource_id, display_name) do
    resource = lock!(Renga.Inventory.Resource, scope.organization_id, resource_id)

    case ResourceStore.update(resource, %{display_name: display_name}) do
      {:ok, _resource} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp record_event!(scope, resource, kind, field, old_value, new_value) do
    {:ok, _event} =
      Inventory.create_change_event(scope, %{
        kind: kind,
        field: field,
        resource_id: resource.id,
        old_value: event_value(old_value),
        new_value: event_value(new_value)
      })
  end

  defp event_value(nil), do: nil
  defp event_value(%Decimal{} = value), do: %{"value" => Decimal.to_string(value, :normal)}
  defp event_value(value), do: %{"value" => value}

  defp validate_location!(scope, location_id, site_id) do
    case Repo.get_by(Location, organization_id: scope.organization_id, id: location_id) do
      %Location{site_id: ^site_id} -> :ok
      _other -> Repo.rollback(:location_not_at_site)
    end
  end

  defp validate_rack!(scope, rack_id, site_id) do
    case Repo.get_by(Rack, organization_id: scope.organization_id, id: rack_id) do
      %Rack{site_id: ^site_id} -> :ok
      _other -> Repo.rollback(:rack_not_at_site)
    end
  end

  defp lock!(schema, organization_id, id) do
    schema
    |> where([record], record.organization_id == ^organization_id and record.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp scoped_get!(schema, organization_id, id) do
    schema
    |> where([record], record.organization_id == ^organization_id and record.id == ^id)
    |> Repo.one!()
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
