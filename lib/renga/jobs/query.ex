defmodule Renga.Jobs.Query do
  @moduledoc """
  An operational query (RFD 12): a typed, read-only question an agent answers
  about its host on demand, such as which sockets are listening.

  A query is an `observe` job capability named `query.<name>@<version>`.
  `use Renga.Jobs.Query` makes a module one, and the module declares:

    * `parameters_schema/0` and `result_schema/0` in `Renga.Jobs.Query.Schema`,
      validated by Renga before a job is stored and when the agent reports,
      and by the agent before it runs;
    * `sensitivity/0`: `:inventory` (no more revealing than an observation)
      or `:sensitive` (software versions, running services, or other detail an
      attacker would value);
    * `summary/0`: what it answers, in a phrase for people.

  The capability limits still apply: `timeout_ms/0` (30 seconds unless the
  module sets one) and `output_limit_bytes/0`, which bounds the result. The
  agent truncates list results to fit and says so with `truncated`.

  Running a query and reading what it returned needs RFD 17's explicit
  `queries.run` permission, and a sensitive query also `queries.run_sensitive`.
  `jobs.request` grants neither. Queries are off until an organization allows
  each one, unlike other `observe` capabilities, and a query's text never
  reaches a program's arguments on the agent.
  """

  alias Renga.Jobs.Query.Schema
  alias Renga.Jobs.Registry

  @type sensitivity :: :inventory | :sensitive

  @callback sensitivity() :: sensitivity()
  @callback summary() :: String.t()
  @callback parameters_schema() :: term()
  @callback result_schema() :: term()

  @default_timeout_ms :timer.seconds(30)

  defmacro __using__(_opts) do
    quote do
      use Renga.Jobs.Capability

      @behaviour Renga.Jobs.Query

      @impl Renga.Jobs.Capability
      def risk_class, do: :observe

      # Reading a host's state again just reads it again.
      @impl Renga.Jobs.Capability
      def retry_class, do: :idempotent

      @impl Renga.Jobs.Capability
      def timeout_ms, do: unquote(@default_timeout_ms)

      @impl Renga.Jobs.Capability
      def sensitive_output?, do: true

      @impl Renga.Jobs.Capability
      def allowed_by_default?, do: false

      @impl Renga.Jobs.Capability
      def required_permissions, do: Renga.Jobs.Query.permissions(sensitivity())

      @impl Renga.Jobs.Capability
      def parameters_changeset(params),
        do: Renga.Jobs.Query.Schema.changeset(parameters_schema(), params)

      @impl Renga.Jobs.Capability
      def result_changeset(result),
        do: Renga.Jobs.Query.Schema.changeset(result_schema(), result)

      defoverridable timeout_ms: 0
    end
  end

  @doc "The permissions running a query of `sensitivity`, and reading its payloads, needs."
  def permissions(:inventory), do: ["queries.run"]
  def permissions(:sensitive), do: ["queries.run", "queries.run_sensitive"]

  @doc "Whether a capability module is a query."
  def query?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :sensitivity, 0)
  end

  @doc "Every registered query module."
  def all, do: Enum.filter(Registry.all(), &query?/1)

  @doc "Every registered query's `name@version` key."
  def keys, do: Enum.map(all(), &Renga.Jobs.Capability.key/1)

  @doc "The fields of a query's parameters, for a form."
  def parameter_fields(module), do: Schema.fields(module.parameters_schema())
end
