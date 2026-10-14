defmodule Renga.Jobs.Capability do
  @moduledoc """
  A named, versioned operation an agent can run as a job (RFD 9).

  Each capability is one module implementing this behaviour, registered in
  `Renga.Jobs.Registry` under its `name@version` key. The job context, the
  delivery endpoints, and the lease sweeper know nothing about any one
  capability; later RFDs add capabilities as new modules without changing them.

  A capability's risk and retry classes are part of its version. Changing
  either means publishing a new version, so a job's rules cannot change after
  it was requested.

  `use Renga.Jobs.Capability` supplies defaults for the optional callbacks.
  """

  alias Renga.Accounts.Scope
  alias Renga.Inventory.Agent

  @typedoc "What a run can do to the host: report, change it, or open a session."
  @type risk_class :: :observe | :operate | :interactive

  @typedoc "How safe running it again is after a lost lease."
  @type retry_class :: :idempotent | :convergent | :imperative

  @callback name() :: String.t()
  @callback version() :: pos_integer()
  @callback risk_class() :: risk_class()
  @callback retry_class() :: retry_class()

  @doc "Casts and validates request parameters into a schemaless changeset."
  @callback parameters_changeset(params :: map()) :: Ecto.Changeset.t()

  @doc "Casts and validates the agent's final result into a schemaless changeset."
  @callback result_changeset(result :: map()) :: Ecto.Changeset.t()

  @doc "How long an agent may run the job before reporting it failed."
  @callback timeout_ms() :: pos_integer()

  @doc "Total bytes of agent-supplied event payloads one job may record."
  @callback output_limit_bytes() :: pos_integer()

  @doc "Whether output must be hidden from people who may not request the job."
  @callback sensitive_output?() :: boolean()

  @doc """
  Narrows the organization and role checks for one request. It runs only after
  those checks pass, so it can refuse a request but never permit one they
  refused.
  """
  @callback authorize(Scope.t(), Agent.t(), parameters :: map()) :: :ok | {:error, term()}

  @doc "A one-line description of a successful result for people."
  @callback describe_result(result :: map()) :: String.t()

  @optional_callbacks authorize: 3, sensitive_output?: 0, describe_result: 1

  # Initial bound from RFD 9 so a job can never become an unbounded log sink.
  @default_output_limit_bytes 64 * 1024

  defmacro __using__(_opts) do
    quote do
      @behaviour Renga.Jobs.Capability

      @impl Renga.Jobs.Capability
      def output_limit_bytes, do: unquote(@default_output_limit_bytes)

      @impl Renga.Jobs.Capability
      def sensitive_output?, do: false

      @impl Renga.Jobs.Capability
      def authorize(_scope, _agent, _parameters), do: :ok

      @impl Renga.Jobs.Capability
      def describe_result(_result), do: "Completed"

      defoverridable output_limit_bytes: 0, sensitive_output?: 0, authorize: 3, describe_result: 1
    end
  end

  @doc "The `name@version` key of a capability module."
  def key(module), do: "#{module.name()}@#{module.version()}"

  @doc """
  Splits a `name@version` key. Entries without a version, such as
  `host.inventory`, describe what an agent reports rather than jobs it
  accepts, so they are not capability keys.
  """
  def parse_key(key) when is_binary(key) do
    with [name, version] <- String.split(key, "@"),
         true <- name =~ ~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/,
         {version, ""} when version > 0 <- Integer.parse(version) do
      {:ok, {name, version}}
    else
      _invalid -> :error
    end
  end

  def parse_key(_key), do: :error
end
