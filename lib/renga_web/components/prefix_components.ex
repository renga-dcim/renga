defmodule RengaWeb.PrefixComponents do
  @moduledoc """
  Prefix-view pieces shared by the prefix list and a prefix's page (RFD 8,
  "Prefixes"): what "used" means at each scale, IPv6 addresses with their
  shared prefix dimmed, and address counts that stay readable at IPv6
  sizes.
  """
  use Phoenix.Component

  import RengaWeb.CoreComponents, only: [input: 1]

  alias Renga.Inventory.Prefix
  alias Renga.IPAM.Cidr
  alias Renga.IPAM.Vrf

  @doc """
  Renders a prefix's usage: children allocated for a container ("5 of 256
  /56s"), a utilization bar for a small IPv4 leaf, and an address count
  otherwise, never a percentage.
  """
  attr :usage, :map, required: true
  attr :id, :string, default: nil

  def usage(%{usage: %{kind: :children}} = assigns) do
    ~H"""
    <span id={@id} data-usage="children" class="font-mono text-xs tabular-nums text-fg-muted">
      <span class="text-fg">{delimit(@usage.allocated)}</span>
      of {delimit(@usage.total)} /{@usage.level}s
    </span>
    """
  end

  def usage(%{usage: %{kind: :percent}} = assigns) do
    ~H"""
    <span id={@id} data-usage="percent" class="inline-flex items-center gap-2">
      <span class="block h-1.5 w-16 overflow-hidden rounded-full bg-sunken" aria-hidden="true">
        <span
          class={["block h-full rounded-full", bar_class(@usage.percent)]}
          style={"width: #{@usage.percent}%"}
        />
      </span>
      <span class="font-mono text-xs tabular-nums text-fg-muted">{@usage.percent}%</span>
    </span>
    """
  end

  def usage(%{usage: %{kind: :count}} = assigns) do
    ~H"""
    <span id={@id} data-usage="count" class="font-mono text-xs tabular-nums text-fg-muted">
      {delimit(@usage.count)} {if @usage.count == 1, do: "address", else: "addresses"}
    </span>
    """
  end

  @doc """
  Renders an address. IPv6 addresses inside a prefix dim the groups they
  share with it, so interface identifiers stand out.
  """
  attr :address, :any, required: true, doc: "a Postgrex.INET"
  attr :prefix_length, :integer, default: nil

  def address(assigns) do
    assigns =
      assign(
        assigns,
        :parts,
        if(Cidr.family(assigns.address) == :ipv6 and assigns.prefix_length,
          do: Cidr.split_ipv6(assigns.address, assigns.prefix_length)
        )
      )

    ~H"""
    <span class="font-mono text-sm">
      <%= if @parts do %>
        <span class="text-fg-subtle">{elem(@parts, 0)}</span><span class="text-fg">{elem(@parts, 1)}</span>
      <% else %>
        <span class="text-fg">{Cidr.format(@address)}</span>
      <% end %>
    </span>
    """
  end

  @doc """
  Renders how many addresses a prefix holds, readable at any size: digits
  for IPv4 and small prefixes, a power of two for large IPv6 prefixes.
  """
  attr :cidr, :any, required: true

  def size(assigns) do
    assigns =
      assign(assigns,
        exponent: Cidr.bits(Cidr.family(assigns.cidr)) - Cidr.length(assigns.cidr),
        count: Cidr.size(assigns.cidr)
      )

    ~H"""
    <span :if={@exponent > 32} class="font-mono">2<sup>{@exponent}</sup></span>
    <span :if={@exponent <= 32} class="font-mono">{delimit(@count)}</span>
    """
  end

  @doc """
  The fields of the prefix create and edit forms. The routing table is
  picked from the organization's VRFs (RFD 4, Phase 2), so a typo can no
  longer quietly start a new table; VRFs are created on their own.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :tables, :list, required: true, doc: "the routing tables, nil for global, then VRFs"

  def prefix_fields(assigns) do
    assigns =
      assign(assigns,
        table_options: Enum.map(assigns.tables, &table_option/1),
        statuses: Enum.map(Prefix.statuses(), &{String.capitalize(&1), &1})
      )

    ~H"""
    <.input
      field={@form[:prefix]}
      value={cidr_text(@form[:prefix].value)}
      type="text"
      label="CIDR"
      placeholder="10.0.0.0/24 or 2001:db8::/48"
      autocomplete="off"
      spellcheck="false"
    />
    <.input field={@form[:vrf_id]} type="select" label="Routing table" options={@table_options} />
    <.input field={@form[:status]} type="select" label="Status" options={@statuses} />
    <.input field={@form[:description]} type="text" label="Description (optional)" />
    """
  end

  defp table_option(nil), do: {"Global", ""}
  defp table_option(vrf), do: {vrf.name, vrf.id}

  # A stored prefix is a Postgrex.INET; a typed one is still text.
  defp cidr_text(%Postgrex.INET{} = cidr), do: Cidr.format(cidr)
  defp cidr_text(text), do: text

  @doc "`IPv4` or `IPv6`."
  def family_label(:ipv4), do: "IPv4"
  def family_label(:ipv6), do: "IPv6"

  @doc "A routing table's name: `Global` or the VRF."
  def table_label(nil), do: "Global"
  def table_label(%Vrf{name: name}), do: name

  @doc "Groups digits in thousands: 65536 -> 65,536."
  def delimit(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp bar_class(percent) when percent >= 90, do: "bg-crit"
  defp bar_class(percent) when percent >= 75, do: "bg-warn"
  defp bar_class(_percent), do: "bg-accent"
end
