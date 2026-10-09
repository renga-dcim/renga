defmodule RengaWeb.VlanComponents do
  @moduledoc """
  VLAN-area pieces shared by the VLAN list and a VLAN's detail (RFD 8,
  "VLANs"): the ID-range usage strip and prefix formatting.
  """
  use Phoenix.Component

  @doc """
  Renders a group's ID-range usage (`Renga.Topology.VlanUsage.strip/2`).

  Each range is a segment as wide as its share of the group's IDs, with a
  tick for every ID that holds a VLAN. Ticks have a minimum width, so one
  VLAN in a 4,094-ID range still shows.
  """
  attr :id, :string, required: true
  attr :usage, :map, required: true

  def usage_strip(assigns) do
    assigns =
      assign(assigns,
        segments:
          Enum.map(assigns.usage.segments, fn segment ->
            Map.put(segment, :share, segment.size / max(assigns.usage.capacity, 1) * 100)
          end)
      )

    ~H"""
    <span
      id={@id}
      role="img"
      aria-label={"#{@usage.used} of #{@usage.capacity} IDs hold a VLAN"}
      class="flex h-2.5 min-w-0 gap-0.5"
    >
      <span
        :for={segment <- @segments}
        data-range={"#{segment.start_vid}-#{segment.end_vid}"}
        data-used={length(segment.used)}
        title={"#{segment.start_vid}–#{segment.end_vid}: #{length(segment.used)} of #{segment.size} used"}
        class="relative h-full min-w-1 overflow-hidden rounded-sm bg-sunken ring-1 ring-edge ring-inset"
        style={"flex: #{segment.share} 1 0%"}
      >
        <span
          :for={vid <- segment.used}
          class="absolute inset-y-0 min-w-0.5 bg-accent"
          style={"left: min(#{offset(segment, vid)}%, calc(100% - max(0.125rem, #{100 / segment.size}%))); width: #{100 / segment.size}%"}
        />
      </span>
    </span>
    """
  end

  @doc "A group's ranges as text, such as `1–99, 200–299`."
  def ranges_label(%{vid_ranges: ranges}) do
    ranges
    |> Enum.sort_by(& &1.start_vid)
    |> Enum.map_join(", ", fn
      %{start_vid: vid, end_vid: vid} -> to_string(vid)
      range -> "#{range.start_vid}–#{range.end_vid}"
    end)
  end

  @doc "A prefix's CIDR, such as `10.0.10.0/24`."
  def prefix_cidr(prefix) do
    address = prefix.prefix.address |> :inet.ntoa() |> List.to_string()
    "#{address}/#{prefix.prefix.netmask}"
  end

  defp offset(segment, vid), do: (vid - segment.start_vid) / segment.size * 100
end
