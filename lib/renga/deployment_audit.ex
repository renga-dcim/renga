defmodule Renga.DeploymentAudit do
  @moduledoc """
  The deployment audit log (RFD 22, "Audit"): every attempted operator
  mutation, whether a release command or the operator API made it.

  A context names who acted and in which invocation:

    * `actor` is `{:operator, name}` for a release command, where `name` is
      the `--actor` the person running it gave, as `bin/providers` does, or
      `{:token, token}` for an operator token calling the API.
    * `invocation_id` is the release command's generated invocation ID or the
      API request's ID.

  `mutate/3` commits a successful change and its event in one transaction, so
  neither exists without the other. A refused change rolls back and is then
  recorded as `rejected`, and one that raises as `failed`. Events hold an
  allowlisted summary, never request bodies, arguments as typed, credentials,
  or secrets.
  """

  alias Renga.DeploymentAudit.Event
  alias Renga.Operators.OperatorToken
  alias Renga.Repo

  @doc """
  A context for a release command run by `actor_name`, with a fresh
  invocation ID.
  """
  def operator(actor_name) when is_binary(actor_name) do
    %{actor: {:operator, actor_name}, invocation_id: Ecto.UUID.generate()}
  end

  @doc "A context for an operator token's API request `request_id`."
  def token(%OperatorToken{} = token, request_id) when is_binary(request_id) do
    %{actor: {:token, token}, invocation_id: request_id}
  end

  @doc """
  Runs `fun` in a transaction and records its outcome as `operation`.

  `fun` returns `{:ok, value, details}` to commit, or `{:error, reason,
  details}` to roll back, where `details` may hold `:target_id`,
  `:organization`, and `:changed`, the names of the fields it changed.
  `reason` is recorded as an allowlisted code: an atom's name, or `invalid`
  for a changeset. An idempotent `:replayed` result records nothing because
  the original attempt already recorded the one mutation. Returns `{:ok,
  value}` or `{:error, reason}`.
  """
  def mutate(context, operation, fun) do
    result =
      try do
        Repo.transaction(fn ->
          case fun.() do
            {:ok, value, details} ->
              record!(context, operation, "succeeded", details)
              value

            {:error, reason, details} ->
              Repo.rollback({reason, details})
          end
        end)
      rescue
        exception ->
          record!(context, operation, "failed", %{reason: "exception"})
          reraise exception, __STACKTRACE__
      end

    case result do
      {:ok, value} ->
        {:ok, value}

      {:error, {:replayed, _details}} ->
        {:error, :replayed}

      {:error, {reason, details}} ->
        record!(context, operation, "rejected", Map.put(details, :reason, reason_code(reason)))
        {:error, reason}
    end
  end

  @doc """
  Records an attempt refused before it reached a change, such as one naming a
  target that does not exist, and returns `{:error, reason}`.
  """
  def reject(context, operation, reason, details \\ %{}) do
    record!(context, operation, "rejected", Map.put(details, :reason, reason_code(reason)))
    {:error, reason}
  end

  @doc """
  How `context`'s actor reads in records, such as `operator: Jane`, for an
  organization's Activity entry about the same change.
  """
  def actor_label(%{actor: actor}), do: label(actor)

  defp record!(%{actor: actor, invocation_id: invocation_id}, operation, outcome, details) do
    organization = details[:organization]

    Repo.insert!(%Event{
      operation: operation,
      outcome: outcome,
      actor: label(actor),
      actor_token_id: actor_token_id(actor),
      invocation_id: invocation_id,
      target_id: details[:target_id],
      organization_id: organization && organization.id,
      organization_name: organization && organization.name,
      changed: details |> Map.get(:changed, []) |> Enum.map(&to_string/1),
      reason: details[:reason]
    })
  end

  defp label({:operator, name}) when is_binary(name), do: "operator: #{name}"
  defp label({:token, %OperatorToken{name: name}}), do: "token: #{name}"

  defp actor_token_id({:token, %OperatorToken{id: id}}), do: id
  defp actor_token_id({:operator, _name}), do: nil

  defp reason_code(%Ecto.Changeset{}), do: "invalid"
  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
end
