defmodule RengaWeb.TopologyComponents do
  @moduledoc """
  The topology map and link-state vocabulary (RFD 8, "Topology").

  A link's line style encodes how its plan, evidence, and cable record
  agree, and the same style appears in the legend, the link table, and the
  link panel so it is learned once. Styles differ in dash pattern as well as
  colour, so they stay distinct without colour vision.

  The map is server-rendered: edges are SVG paths and devices are ordinary
  links positioned over them, so no client layout code is needed and every
  device stays a focusable, labelled control.
  """
  use Phoenix.Component
  use Gettext, backend: RengaWeb.Gettext

  import RengaWeb.CoreComponents, only: [icon: 1]
  import RengaWeb.InventoryComponents, only: [kind_icon: 1]

  alias Renga.Topology.Links

  @node_w 128
  @node_h 36
  @gap_x 16
  @row_gap 40
  @tier_gap 84
  @label_h 22
  @pad 20
  @per_row 8

  @doc "A short label for a link state."
  def state_label(:agreeing), do: gettext("Agreeing")
  def state_label(:recorded), do: gettext("Recorded, not seen")
  def state_label(:unrecorded), do: gettext("Seen, not recorded")
  def state_label(:planned), do: gettext("Planned, not seen")
  def state_label(:disagreeing), do: gettext("Disagreeing")

  @doc "What a link state means, for the panel and legend."
  def state_description(:agreeing),
    do: gettext("The cable record and neighbor evidence agree on this pair.")

  def state_description(:recorded),
    do: gettext("A cable is recorded, but no neighbor evidence currently sees it.")

  def state_description(:unrecorded),
    do: gettext("Neighbor evidence sees this pair, but no cable is recorded.")

  def state_description(:planned),
    do: gettext("This cable is planned, but nothing sees or records it yet.")

  def state_description(:disagreeing),
    do: gettext("The plan, evidence, or record connect an endpoint to a different neighbor.")

  @doc """
  Renders a short sample of a state's line, for legends and table cells.
  """
  attr :state, :atom, required: true
  attr :class, :any, default: nil

  def line_sample(assigns) do
    ~H"""
    <svg viewBox="0 0 28 8" class={["h-2 w-7 shrink-0", @class]} aria-hidden="true">
      <line x1="1" y1="4" x2="27" y2="4" {line_attrs(@state)} class={line_class(@state)} />
      <rect
        :if={@state == :disagreeing}
        x="11"
        y="1"
        width="6"
        height="6"
        transform="rotate(45 14 4)"
        class="fill-warn"
      />
    </svg>
    """
  end

  @doc "Renders a link state as its line sample and label."
  attr :state, :atom, required: true
  attr :id, :string, default: nil

  def link_state(assigns) do
    ~H"""
    <span id={@id} data-link-state={@state} class="inline-flex items-center gap-2 whitespace-nowrap">
      <.line_sample state={@state} />
      <span class={["text-xs", state_text_class(@state)]}>{state_label(@state)}</span>
    </span>
    """
  end

  @doc "Renders the legend of link states with how many links are in each."
  attr :id, :string, required: true
  attr :counts, :map, required: true

  def legend(assigns) do
    assigns = assign(assigns, :states, Links.states())

    ~H"""
    <ul id={@id} class="flex flex-wrap gap-x-5 gap-y-2">
      <li
        :for={state <- @states}
        id={"#{@id}-#{state}"}
        title={state_description(state)}
        class="flex items-center gap-2 text-xs text-fg-muted"
      >
        <.line_sample state={state} />
        <span>{state_label(state)}</span>
        <span class="font-mono tabular-nums text-fg">{@counts[state]}</span>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a `Renga.Topology.LinkMap`.

  Clicking an edge pushes `select_edge` with the edge's most urgent link;
  `node_path` gives the patch path for a device, which focuses the map on
  it.
  """
  attr :id, :string, required: true
  attr :map, Renga.Topology.LinkMap, required: true
  attr :selected, :string, default: nil, doc: "the selected link key"
  attr :focus, :string, default: nil, doc: "the focused resource id"
  attr :node_path, :any, required: true

  def link_map(assigns) do
    assigns = assign(assigns, :layout, layout(assigns.map))

    ~H"""
    <div id={@id} phx-hook="CenterScroll" class="overflow-x-auto">
      <div
        class="relative mx-auto"
        style={"width: #{@layout.width}px; height: #{@layout.height}px"}
      >
        <svg
          class="absolute inset-0"
          width={@layout.width}
          height={@layout.height}
          viewBox={"0 0 #{@layout.width} #{@layout.height}"}
          role="group"
          aria-label={gettext("Links between devices")}
        >
          <g
            :for={edge <- @layout.edges}
            id={"#{@id}-edge-#{edge.id}"}
            data-edge-state={edge.state}
            data-selected={to_string(@selected in edge.link_keys)}
            phx-click="select_link"
            phx-value-link={edge.primary}
            phx-keydown="select_link"
            phx-key="Enter"
            tabindex="0"
            role="button"
            aria-label={edge_label(edge)}
            class="group cursor-pointer outline-none"
          >
            <path d={edge.path} class="fill-none stroke-transparent" stroke-width="14" />
            <path
              :if={@selected in edge.link_keys}
              d={edge.path}
              class="fill-none stroke-accent/30"
              stroke-width="8"
            />
            <path
              d={edge.path}
              {line_attrs(edge.state)}
              class={[
                "fill-none transition-[stroke-width] group-hover:[stroke-width:3.5]",
                "group-focus-visible:[stroke-width:3.5]",
                line_class(edge.state)
              ]}
            />
            <rect
              :if={edge.state == :disagreeing}
              x={edge.mid_x - 4.5}
              y={edge.mid_y - 4.5}
              width="9"
              height="9"
              transform={"rotate(45 #{edge.mid_x} #{edge.mid_y})"}
              class="fill-warn stroke-surface"
              stroke-width="1.5"
            />
            <g :if={edge.count > 1}>
              <rect
                x={edge.mid_x + 7}
                y={edge.mid_y - 8}
                width={8 + 7 * String.length(to_string(edge.count))}
                height="16"
                rx="8"
                class="fill-surface stroke-edge"
              />
              <text
                x={edge.mid_x + 11}
                y={edge.mid_y + 4}
                class="fill-fg-muted font-mono text-[11px]"
              >
                {edge.count}
              </text>
            </g>
          </g>
        </svg>

        <p
          :for={tier <- @layout.tiers}
          id={"#{@id}-tier-#{tier.id}"}
          class="absolute text-[11px] font-medium uppercase tracking-wide text-fg-subtle"
          style={"left: #{@layout.pad}px; top: #{tier.label_y}px"}
        >
          {tier.label}
        </p>

        <.link
          :for={node <- @layout.nodes}
          id={"#{@id}-node-#{node.id}"}
          patch={@node_path.(node.resource)}
          data-focused={to_string(@focus == node.id)}
          title={node.resource.name}
          class={[
            "absolute flex items-center gap-1.5 rounded-md border px-2 text-xs shadow-xs transition-colors",
            "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent",
            if(@focus == node.id,
              do: "border-accent bg-accent-tint text-fg",
              else: "border-edge bg-surface text-fg hover:border-fg-subtle hover:bg-sunken"
            )
          ]}
          style={"left: #{node.x}px; top: #{node.y}px; width: #{node.w}px; height: #{node.h}px"}
        >
          <.icon name={kind_icon(node.resource.kind)} class="size-3.5 shrink-0 text-fg-subtle" />
          <span class="truncate font-medium">{node.resource.name}</span>
        </.link>
      </div>
    </div>
    """
  end

  # Pixel geometry for the map. Each tier wraps into rows of at most
  # @per_row devices, centred, so a large tier of hosts grows down instead
  # of off to the side.
  defp layout(map) do
    columns =
      map.tiers
      |> Enum.map(&min(length(&1.nodes), @per_row))
      |> Enum.max(fn -> 1 end)

    width = @pad * 2 + columns * (@node_w + @gap_x) - @gap_x

    {tiers, nodes, bottom} =
      Enum.reduce(map.tiers, {[], [], @pad}, fn tier, {tiers, nodes, y} ->
        tier_label = %{id: tier.id, label: tier.label, label_y: y}

        {rows_nodes, y} =
          tier.nodes
          |> Enum.chunk_every(@per_row)
          |> Enum.map_reduce(y + @label_h, fn row, top ->
            {place_row(row, top, width), top + @node_h + @row_gap}
          end)

        {[tier_label | tiers], nodes ++ List.flatten(rows_nodes), y - @row_gap + @tier_gap}
      end)

    by_id = Map.new(nodes, &{&1.id, &1})

    # Same-row curves rise with their span. Reserve enough canvas for their
    # control points (and markers), including anchors spread within each node.
    headroom =
      map.edges
      |> Enum.map(fn edge ->
        a = Map.fetch!(by_id, edge.a)
        b = Map.fetch!(by_id, edge.b)
        if a.y == b.y, do: max(0, @pad + 28 + div(abs(a.x - b.x) + @node_w, 12) - a.y), else: 0
      end)
      |> Enum.max(fn -> 0 end)

    nodes = Enum.map(nodes, &%{&1 | y: &1.y + headroom})
    tiers = Enum.map(tiers, &%{&1 | label_y: &1.label_y + headroom})
    by_id = Map.new(nodes, &{&1.id, &1})

    %{
      width: width,
      height: bottom - @tier_gap + @pad + headroom,
      pad: @pad,
      tiers: Enum.reverse(tiers),
      nodes: nodes,
      edges: place_edges(map.edges, by_id)
    }
  end

  defp place_row(row, top, width) do
    row_width = length(row) * (@node_w + @gap_x) - @gap_x
    left = div(width - row_width, 2)

    row
    |> Enum.with_index()
    |> Enum.map(fn {resource, index} ->
      %{
        id: resource.id,
        resource: resource,
        x: left + index * (@node_w + @gap_x),
        y: top,
        w: @node_w,
        h: @node_h
      }
    end)
  end

  # Edges leave the bottom of the upper device and enter the top of the
  # lower one; devices in the same row are joined by an arc above them.
  defp place_edges(edges, by_id) do
    ends =
      Enum.map(edges, fn edge ->
        [upper, lower] =
          Enum.sort_by([Map.fetch!(by_id, edge.a), Map.fetch!(by_id, edge.b)], &{&1.y, &1.x})

        {edge, upper, lower, if(upper.y == lower.y, do: :top, else: :bottom)}
      end)

    anchors = anchors(ends)

    Enum.map(ends, fn {edge, upper, lower, upper_side} ->
      ux = Map.fetch!(anchors, {edge.id, upper.id})
      lx = Map.fetch!(anchors, {edge.id, lower.id})

      points =
        case upper_side do
          :top ->
            lift = 28 + div(abs(lx - ux), 12)
            [{ux, upper.y}, {ux, upper.y - lift}, {lx, lower.y - lift}, {lx, lower.y}]

          :bottom ->
            y0 = upper.y + @node_h
            y1 = lower.y
            bend = div(y1 - y0, 2)
            [{ux, y0}, {ux, y0 + bend}, {lx, y1 - bend}, {lx, y1}]
        end

      [{x0, y0}, {x1, y1}, {x2, y2}, {x3, y3}] = points

      Map.merge(edge, %{
        path: "M#{x0} #{y0} C#{x1} #{y1} #{x2} #{y2} #{x3} #{y3}",
        # The curve's point at t = 0.5 carries the marker and count.
        mid_x: (x0 + 3 * x1 + 3 * x2 + x3) / 8,
        mid_y: (y0 + 3 * y1 + 3 * y2 + y3) / 8,
        count: length(edge.link_keys)
      })
    end)
  end

  # Where each edge meets each device. Edges leaving one side of a device
  # spread across its middle in the order of the devices they lead to, so
  # they fan out instead of crossing at one point.
  defp anchors(ends) do
    ends
    |> Enum.flat_map(fn {edge, upper, lower, upper_side} ->
      [
        {{upper.id, upper_side}, {edge.id, center(lower)}},
        {{lower.id, :top}, {edge.id, center(upper)}}
      ]
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {{node_id, _side}, sides} ->
      count = length(sides)
      node_x = Enum.find_value(ends, &node_x(&1, node_id))

      sides
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.with_index()
      |> Enum.map(fn {{edge_id, _other_x}, index} ->
        {{edge_id, node_id}, node_x + anchor_offset(index, count)}
      end)
    end)
    |> Map.new()
  end

  defp anchor_offset(_index, 1), do: div(@node_w, 2)

  defp anchor_offset(index, count) do
    spread = @node_w * 0.6
    round(@node_w * 0.2 + spread * index / (count - 1))
  end

  defp node_x({_edge, %{id: id, x: x}, _lower, _side}, id), do: x
  defp node_x({_edge, _upper, %{id: id, x: x}, _side}, id), do: x
  defp node_x(_end, _id), do: nil

  defp center(node), do: node.x + div(@node_w, 2)

  defp edge_label(edge) do
    gettext("%{a} to %{b}: %{state}, %{count} links",
      a: edge.resource_a.name,
      b: edge.resource_b.name,
      state: state_label(edge.state),
      count: length(edge.link_keys)
    )
  end

  defp line_attrs(:agreeing), do: %{"stroke-width" => "2"}
  defp line_attrs(:recorded), do: %{"stroke-width" => "1.5"}
  defp line_attrs(:unrecorded), do: %{"stroke-width" => "2", "stroke-dasharray" => "6 4"}

  defp line_attrs(:planned),
    do: %{"stroke-width" => "2", "stroke-dasharray" => "0.5 4.5", "stroke-linecap" => "round"}

  defp line_attrs(:disagreeing), do: %{"stroke-width" => "2.5"}

  defp line_class(:agreeing), do: "stroke-ok"
  defp line_class(:recorded), do: "stroke-fg-subtle"
  defp line_class(:unrecorded), do: "stroke-info"
  defp line_class(:planned), do: "stroke-fg-muted"
  defp line_class(:disagreeing), do: "stroke-warn"

  defp state_text_class(:disagreeing), do: "font-medium text-warn-text"
  defp state_text_class(:unrecorded), do: "text-info"
  defp state_text_class(_state), do: "text-fg-muted"
end
