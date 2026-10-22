defmodule Renga.Deployment do
  @moduledoc """
  Facts about this deployment as a whole, rather than any one organization.

  The deployment identifier (RFD 23) is an optional, non-secret name an
  operator gives a deployment, such as `eu1`. Intake keys issued while it is
  set carry it in the open so a resolver can route an agent to its home
  without ever seeing the key's secret. It is an annotation, never part of
  authentication.
  """

  @id_format ~r/\A[a-z0-9](?:[a-z0-9-]{0,14}[a-z0-9])?\z/

  @doc """
  Returns the configured deployment identifier, or `nil` when there is none.
  """
  def id, do: Application.get_env(:renga, :deployment_id)

  @doc """
  Returns whether `value` is a well-formed deployment identifier: at most 16
  lowercase letters, digits, and hyphens, starting and ending with a letter or
  digit.
  """
  def valid_id?(value) when is_binary(value), do: Regex.match?(@id_format, value)
  def valid_id?(_value), do: false

  @doc """
  The URL people and agents reach this deployment at, which is also the
  agent's home (RFD 23). It comes from configuration, never from a request.
  """
  def public_url, do: RengaWeb.Endpoint.url()
end
