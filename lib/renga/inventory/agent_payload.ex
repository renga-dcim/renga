defmodule Renga.Inventory.AgentPayload do
  @moduledoc """
  Validation for source-authenticated agent API payloads.

  The API stores accepted observations before reconciliation, so this module
  keeps the first gate focused on tenant/source identity and payload shape.
  """

  alias Renga.Inventory.Source

  @max_observation_bytes 256_000

  @doc """
  Returns the maximum accepted JSON observation payload size in bytes.
  """
  def max_observation_bytes, do: @max_observation_bytes

  @doc """
  Validates an agent check-in payload and returns attrs safe for the source row.
  """
  def validate_check_in(params, %Source{} = source) when is_map(params) do
    []
    |> validate_source_identity(params, source)
    |> validate_capabilities(params)
    |> validate_metadata(params)
    |> case do
      [] ->
        {:ok,
         %{}
         |> maybe_put(:capabilities, Map.get(params, "capabilities"))
         |> maybe_put(:metadata, Map.get(params, "metadata"))}

      errors ->
        {:error, Enum.reverse(errors)}
    end
  end

  def validate_check_in(_params, %Source{}),
    do: {:error, [error("body", "must be a JSON object")]}

  defp validate_source_identity(errors, params, source) do
    case Map.get(params, "source") do
      nil ->
        errors

      %{} = source_params ->
        errors
        |> validate_source_kind(source_params, source)
        |> validate_source_id(source_params, source)

      _invalid ->
        [error("source", "must be an object") | errors]
    end
  end

  defp validate_source_kind(errors, params, source) do
    case Map.get(params, "kind") do
      nil -> errors
      kind when kind == source.kind -> errors
      _other -> [error("source.kind", "does not match authenticated source") | errors]
    end
  end

  defp validate_source_id(errors, params, source) do
    case Map.get(params, "source_id") do
      nil ->
        errors

      source_id when source_id in [source.id, source.name] ->
        errors

      _other ->
        [error("source.source_id", "does not match authenticated source") | errors]
    end
  end

  defp validate_capabilities(errors, params) do
    case Map.get(params, "capabilities") do
      nil ->
        errors

      capabilities when is_list(capabilities) ->
        if Enum.all?(capabilities, &non_empty_string?/1) do
          errors
        else
          [error("capabilities", "must contain only non-empty strings") | errors]
        end

      _invalid ->
        [error("capabilities", "must be a list of strings") | errors]
    end
  end

  defp validate_metadata(errors, params) do
    case Map.get(params, "metadata") do
      nil -> errors
      metadata when is_map(metadata) -> errors
      _invalid -> [error("metadata", "must be an object") | errors]
    end
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp error(path, message), do: %{path: path, message: message}
end
