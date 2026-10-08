defmodule Renga.Topology.Links do
  @moduledoc """
  Per-link view of RFD 7's three cabling layers for the topology page (RFD 8).

  A link is one canonical interface pair that at least one layer mentions: a
  cable plan (intent), current LLDP/CDP adjacency (evidence), or the
  reconciled cable (the record). The layers stay side by side on the link
  rather than being merged into one "connection", so the page can show where
  they agree and where they do not. The link's state summarises that
  agreement, from most to least in need of attention:

    * `:disagreeing` - another link claims one of this link's endpoints, so
      the plan, the evidence, and the record point at different neighbors;
    * `:unrecorded` - evidence sees the pair but no cable records it;
    * `:planned` - planned, but neither seen nor recorded;
    * `:recorded` - recorded, but nothing currently sees it. Many hosts do
      not speak LLDP, so this is information rather than a problem;
    * `:agreeing` - recorded and seen.

  Building links is pure: callers load the layers (see
  `Renga.Topology.list_links/1`) so the same rules apply to the whole
  organization and to the few links around one endpoint.
  """

  alias Renga.Inventory.Interface
  alias Renga.Topology.Cable
  alias Renga.Topology.CablePlan
  alias Renga.Topology.CurrentInterfaceAdjacency

  @states [:disagreeing, :unrecorded, :planned, :recorded, :agreeing]

  defstruct [
    :key,
    :interface_a,
    :interface_b,
    :plan,
    :cable,
    :adjacency,
    :state,
    contested: []
  ]

  @type state :: :disagreeing | :unrecorded | :planned | :recorded | :agreeing

  @type t :: %__MODULE__{
          key: String.t(),
          interface_a: %Interface{},
          interface_b: %Interface{},
          plan: %CablePlan{} | nil,
          cable: %Cable{} | nil,
          adjacency: %CurrentInterfaceAdjacency{} | nil,
          state: state(),
          contested: [contest()]
        }

  @typedoc """
  Another link on one of this link's endpoints: the shared interface, the
  other link's far interface, and which layers make that claim.
  """
  @type contest :: %{
          interface: %Interface{},
          other: %Interface{},
          key: String.t(),
          layers: [:plan | :evidence | :cable]
        }

  @doc "Link states from most to least in need of attention."
  def states, do: @states

  @doc "Ranks a state so that lower is more in need of attention."
  def severity(state), do: Enum.find_index(@states, &(&1 == state))

  @doc """
  The stable key of an interface pair, independent of endpoint order.

  Keys appear in URLs (`?link=`) and DOM ids, so they are built from
  interface ids joined by a character that is safe in both.
  """
  def key(first_id, second_id) do
    {a, b} = canonical(first_id, second_id)
    "#{a}_#{b}"
  end

  @doc "Parses a link key back into its canonical interface ids."
  def parse_key(key) when is_binary(key) do
    with [first, second] <- String.split(key, "_"),
         {:ok, first} <- Ecto.UUID.cast(first),
         {:ok, second} <- Ecto.UUID.cast(second),
         false <- first == second do
      {:ok, canonical(first, second)}
    else
      _invalid -> :error
    end
  end

  def parse_key(_key), do: :error

  @doc """
  Builds links from cable plans, reconciled cables, and current adjacencies.

  Every record must have both endpoint interfaces loaded. Links are ordered
  most-in-need-of-attention first, then by endpoint resource and name.
  """
  def build(plans, cables, adjacencies) do
    links =
      %{}
      |> put_layer(plans, :plan)
      |> put_layer(cables, :cable)
      |> put_layer(adjacencies, :adjacency)
      |> Map.values()

    by_endpoint =
      links
      |> Enum.flat_map(&[{&1.interface_a.id, &1}, {&1.interface_b.id, &1}])
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    links
    |> Enum.map(&classify(&1, by_endpoint))
    |> Enum.sort_by(&sort_key/1)
  end

  @doc """
  Narrows links to those touching one interface or one resource.

  Contest details still name links outside the filter: a disagreement is
  about the endpoint, wherever its other claim leads.
  """
  def filter(links, opts) do
    interface_id = Keyword.get(opts, :interface_id)
    resource_id = Keyword.get(opts, :resource_id)

    Enum.filter(links, fn link ->
      (is_nil(interface_id) or interface_id in [link.interface_a.id, link.interface_b.id]) and
        (is_nil(resource_id) or
           resource_id in [link.interface_a.resource_id, link.interface_b.resource_id])
    end)
  end

  @doc "Counts links per state, with every state present."
  def counts(links) do
    Enum.reduce(links, Map.new(@states, &{&1, 0}), &Map.update!(&2, &1.state, fn n -> n + 1 end))
  end

  @doc "Which layers a link has, in plan, evidence, cable order."
  def layers(%__MODULE__{} = link) do
    [plan: link.plan, evidence: link.adjacency, cable: link.cable]
    |> Enum.reject(fn {_layer, record} -> is_nil(record) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp put_layer(links, records, field) do
    Enum.reduce(records, links, fn record, links ->
      key = key(record.interface_a_id, record.interface_b_id)
      {interface_a, interface_b} = ordered_interfaces(record)

      link =
        Map.get(links, key, %__MODULE__{
          key: key,
          interface_a: interface_a,
          interface_b: interface_b
        })

      Map.put(links, key, Map.put(link, field, record))
    end)
  end

  # Plans, cables, and adjacencies already store the canonical order, but the
  # key is the contract, so endpoints are ordered here too.
  defp ordered_interfaces(%{interface_a: a, interface_b: b}) do
    if a.id <= b.id, do: {a, b}, else: {b, a}
  end

  # A physical endpoint terminates one direct link. When two links share an
  # endpoint, the layers disagree about its neighbor, whichever layers they
  # are, so both links are marked rather than guessing which one is right.
  defp classify(link, by_endpoint) do
    contested =
      for interface <- [link.interface_a, link.interface_b],
          other <- Map.fetch!(by_endpoint, interface.id),
          other.key != link.key do
        %{
          interface: interface,
          other: far_end(other, interface.id),
          key: other.key,
          layers: layers(other)
        }
      end

    %{link | contested: contested, state: state(link, contested)}
  end

  defp state(_link, [_ | _]), do: :disagreeing

  defp state(%{cable: cable, adjacency: adjacency}, [])
       when not is_nil(cable) and not is_nil(adjacency), do: :agreeing

  defp state(%{adjacency: adjacency}, []) when not is_nil(adjacency), do: :unrecorded
  defp state(%{cable: cable}, []) when not is_nil(cable), do: :recorded
  defp state(_link, []), do: :planned

  defp far_end(%{interface_a: %{id: id}, interface_b: other}, id), do: other
  defp far_end(%{interface_a: other}, _id), do: other

  defp sort_key(link) do
    {severity(link.state), resource_name(link.interface_a), link.interface_a.name,
     resource_name(link.interface_b), link.interface_b.name}
  end

  defp resource_name(%Interface{resource: %{name: name}}), do: name
  defp resource_name(_interface), do: ""

  defp canonical(first, second) when first <= second, do: {first, second}
  defp canonical(first, second), do: {second, first}
end
