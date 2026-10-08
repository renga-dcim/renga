defmodule RengaWeb.ElevationComponents do
  @moduledoc """
  The rack elevation (RFD 8, "Places"): one face of a rack drawn on a grid of
  rack units. Empty units are faint rows, each device is a single block
  spanning its height, and a device seen here but recorded elsewhere is a
  dashed block. Unit height comes from the `rack-u` density token, so the
  compact density draws a shorter rack without any screen special-casing it.

  Free units are buttons for people who can place devices: choosing one
  opens the placement panel at that unit. Drag-to-place drops onto the same
  elements, so both paths share one target.
  """
  use RengaWeb, :html

  alias Renga.DCIM.Elevation

  @status_labels %{
    confirmed: "Confirmed",
    observed: "Observed",
    stale: "Stale evidence",
    inferred: "Inferred"
  }

  attr :id, :string, required: true
  attr :face, :string, required: true, values: ~w(front rear)
  attr :elevation, Elevation, required: true
  attr :can_place?, :boolean, default: false
  attr :class, :any, default: nil

  @doc "One face of a rack, top unit first."
  def rack_face(assigns) do
    rack = assigns.elevation.rack

    assigns =
      assigns
      |> assign(:height, rack.height_units)
      |> assign(:bottom_up?, rack.starting_unit != "top")
      |> assign(:units, units(rack))
      |> assign(:blocks, Map.fetch!(assigns.elevation, String.to_existing_atom(assigns.face)))
      |> assign(:ghosts, ghosts(assigns.elevation, assigns.face))
      |> assign(:free, Elevation.free_count(assigns.elevation, assigns.face))

    ~H"""
    <section id={@id} data-face={@face} aria-labelledby={"#{@id}-title"} class={["min-w-0", @class]}>
      <h2 id={"#{@id}-title"} class="mb-2 flex items-baseline gap-2 text-xs font-medium text-fg-muted">
        {face_label(@face)}
        <span class="font-mono tabular-nums text-fg-subtle">{@free}U free</span>
      </h2>
      <div class="grid grid-cols-[2.25rem_minmax(0,1fr)] overflow-hidden rounded-md border border-edge bg-surface">
        <ol class="grid border-r border-edge bg-sunken" style={rows_style(@height)} aria-hidden="true">
          <li
            :for={unit <- @units}
            class="flex items-center justify-end pr-1.5 font-mono text-[10px] leading-none text-fg-subtle"
          >
            {unit}
          </li>
        </ol>
        <div class="grid" style={rows_style(@height)} data-rack-face={@face}>
          <%= for unit <- @units, Elevation.free_unit?(@elevation, unit, @face) do %>
            <button
              :if={@can_place?}
              id={"unit-#{@face}-#{unit}"}
              type="button"
              data-unit={unit}
              data-face={@face}
              phx-click={
                JS.push("open_place", value: %{position: unit, face: @face})
                |> show_overlay("place-panel")
              }
              style={area_style(@height, @bottom_up?, unit, 1)}
              aria-label={"Place a device at U#{unit} #{@face}"}
              class="col-start-1 cursor-pointer border-b border-edge/50 transition-colors hover:bg-accent-tint focus-visible:bg-accent-tint focus-visible:outline-none"
            />
            <div
              :if={!@can_place?}
              id={"unit-#{@face}-#{unit}"}
              data-unit={unit}
              style={area_style(@height, @bottom_up?, unit, 1)}
              class="col-start-1 border-b border-edge/40"
            />
          <% end %>

          <.link
            :for={block <- @blocks}
            id={"block-#{block.id}"}
            navigate={~p"/inventory/#{block.resource}"}
            data-status={block.status}
            data-position={block.position}
            style={area_style(@height, @bottom_up?, block.position, block.height)}
            title={block_title(block)}
            class={[
              "z-10 col-start-1 m-px flex min-w-0 items-center gap-2 overflow-hidden rounded-sm border border-l-[3px] bg-sunken px-2 text-left",
              "transition-colors hover:bg-accent-tint focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring",
              status_border(block.status)
            ]}
          >
            <span class="min-w-0 flex-1 truncate text-[11px] font-medium leading-tight text-fg">
              {block.resource.name}
            </span>
            <span :if={block.face == "full"} class="shrink-0 text-[10px] text-fg-muted">
              Full depth
            </span>
            <span
              :if={block.planned_rack}
              class="shrink-0 font-mono text-[10px] text-warn-text"
              data-planned={block.planned_rack.id}
            >
              → {block.planned_rack.resource.name}
            </span>
            <span class="shrink-0 font-mono text-[10px] tabular-nums text-fg-subtle">
              {block.height}U
            </span>
            <span class="sr-only">{status_label(block.status)}</span>
          </.link>

          <div
            :for={ghost <- @ghosts}
            id={"ghost-#{@face}-#{ghost.resource.id}"}
            data-observed={ghost.via}
            style={area_style(@height, @bottom_up?, ghost.position, ghost.height)}
            class="z-20 col-start-1 m-px flex min-w-0 items-center gap-2 overflow-hidden rounded-sm border-2 border-dashed border-warn-line bg-warn-fill/60 px-2"
          >
            <span class="min-w-0 flex-1 truncate text-[11px] font-medium leading-tight text-warn-text">
              {ghost.resource.name}
            </span>
            <span class="shrink-0 text-[10px] text-warn-text">Seen here</span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :ghost, :map, required: true
  attr :can_place?, :boolean, default: false

  @doc "A device seen in this rack but recorded elsewhere, with its one-step fix."
  def observed_item(assigns) do
    ~H"""
    <li
      id={"observed-#{@ghost.resource.id}"}
      class="space-y-1.5 rounded-md border-2 border-dashed border-warn-line bg-warn-fill/40 px-3 py-2"
    >
      <div class="flex items-baseline justify-between gap-2">
        <.link
          navigate={~p"/inventory/#{@ghost.resource}"}
          class="truncate text-sm font-medium text-fg hover:underline"
        >
          {@ghost.resource.name}
        </.link>
        <span :if={@ghost.position} class="shrink-0 font-mono text-[11px] text-fg-muted">
          {unit_range(@ghost.position, @ghost.height)} · {@ghost.face}
        </span>
      </div>
      <p class="text-xs text-fg-muted">
        {seen_how(@ghost)} · {recorded_where(@ghost.recorded)}
      </p>
      <.button
        :if={@can_place?}
        id={"observed-#{@ghost.resource.id}-place"}
        size="sm"
        phx-click={JS.push("place_observed", value: %{id: @ghost.resource.id})}
        phx-disable-with="Placing…"
      >
        Place here
      </.button>
    </li>
    """
  end

  @doc "Unit numbers for a device starting at `position`, such as U12 or U12–13."
  def unit_range(position, 1), do: "U#{position}"
  def unit_range(position, height), do: "U#{position}–#{position + height - 1}"

  defp face_label("front"), do: "Front"
  defp face_label("rear"), do: "Rear"

  # Observed devices with known units on this face; full depth shows on both.
  defp ghosts(elevation, face) do
    Enum.filter(elevation.observed, fn ghost ->
      ghost.position && ghost.face in [face, "full"] &&
        Enum.all?(
          ghost.position..(ghost.position + ghost.height - 1),
          &Elevation.free_unit?(elevation, &1, face)
        )
    end)
  end

  defp units(%{height_units: height, starting_unit: "top"}), do: Enum.to_list(1..height)
  defp units(%{height_units: height}), do: Enum.to_list(height..1//-1)

  defp rows_style(height), do: "grid-template-rows: repeat(#{height}, var(--spacing-rack-u))"

  # Grid row for a device, counting rows from the top of the drawing.
  defp area_style(height, true, position, span),
    do: "grid-row: #{height - (position + span - 1) + 1} / span #{span}"

  defp area_style(_height, false, position, span), do: "grid-row: #{position} / span #{span}"

  defp status_border(:confirmed), do: "border-edge border-l-ok"
  defp status_border(:observed), do: "border-edge border-l-info"
  defp status_border(:stale), do: "border-warn-line border-l-warn"
  defp status_border(:inferred), do: "border-edge border-l-fg-subtle"

  defp status_label(status), do: Map.fetch!(@status_labels, status)

  defp block_title(block) do
    [
      block.resource.name,
      unit_range(block.position, block.height),
      status_label(block.status),
      block.planned_rack && "planned for #{block.planned_rack.resource.name}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp seen_how(%{via: :lldp}), do: "Seen through LLDP from this rack's switch"
  defp seen_how(%{via: :evidence, source: %{name: name}}), do: "Reported here by #{name}"
  defp seen_how(%{via: :evidence}), do: "Reported here"

  defp recorded_where(nil), do: "not placed anywhere"

  defp recorded_where(placement) do
    place =
      [placement.site, placement.location, placement.rack]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" / ", & &1.resource.name)

    "recorded at #{place}"
  end
end
