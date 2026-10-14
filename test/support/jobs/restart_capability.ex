defmodule Renga.Jobs.TestCapabilities.Restart do
  @moduledoc """
  A test-only imperative capability, so tests can exercise retry classes and
  `uncertain` outcomes before any real `operate` capability exists.
  """

  use Renga.Jobs.Capability

  import Ecto.Changeset

  @impl true
  def name, do: "test.restart"

  @impl true
  def version, do: 1

  @impl true
  def risk_class, do: :operate

  @impl true
  def retry_class, do: :imperative

  @impl true
  def timeout_ms, do: 1_000

  @impl true
  def output_limit_bytes, do: 256

  @impl true
  def parameters_changeset(params) do
    {%{}, %{service: :string}}
    |> cast(params, [:service])
    |> validate_required([:service])
  end

  @impl true
  def result_changeset(result), do: cast({%{}, %{}}, result, [])
end
