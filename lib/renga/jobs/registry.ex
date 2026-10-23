defmodule Renga.Jobs.Registry do
  @moduledoc """
  Maps `name@version` keys to `Renga.Jobs.Capability` modules.

  The list is configuration rather than discovery so a capability exists only
  once it is deliberately added here (tests add their own through
  `config :renga, Renga.Jobs.Registry, extra_capabilities: [...]`).
  """

  alias Renga.Jobs.Capability

  @default_capabilities [
    Renga.Jobs.Capabilities.InventoryCollect,
    Renga.Jobs.Queries.ListeningSockets,
    Renga.Jobs.Queries.Services,
    Renga.Jobs.Queries.DiskUsage,
    Renga.Jobs.Queries.Routes,
    Renga.Jobs.Queries.TimeSync,
    Renga.Jobs.Queries.Packages,
    Renga.Jobs.Queries.Sql
  ]

  @doc "Every registered capability module."
  def all do
    config = Application.get_env(:renga, __MODULE__, [])
    @default_capabilities ++ Keyword.get(config, :extra_capabilities, [])
  end

  @doc "Every registered `name@version` key."
  def keys, do: Enum.map(all(), &Capability.key/1)

  @doc "Finds the module registered for a `name@version` key."
  def fetch(key) when is_binary(key) do
    case Enum.find(all(), &(Capability.key(&1) == key)) do
      nil -> {:error, :unknown_capability}
      module -> {:ok, module}
    end
  end

  def fetch(_key), do: {:error, :unknown_capability}

  @doc "Keys an organization allows until it chooses its own list."
  def default_allowed_keys do
    for module <- all(), module.allowed_by_default?(), do: Capability.key(module)
  end

  @doc "Keys of the registered capabilities in one risk class."
  def keys_with_risk(risk_class) do
    for module <- all(), module.risk_class() == risk_class, do: Capability.key(module)
  end
end
