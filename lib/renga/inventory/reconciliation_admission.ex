defmodule Renga.Inventory.ReconciliationAdmission do
  @moduledoc false
  # The caller holds the organization row and advisory locks. Credential and
  # installation identities are explicit. Used only when accepting new evidence;
  # accepted work never depends on these credentials remaining live.
  import Ecto.Query

  alias Renga.Inventory.Agent
  alias Renga.Inventory.IntakeApiKey
  alias Renga.Inventory.Source
  alias Renga.Repo

  def current(organization_id, key_id, agent_id, installation_id, source_id)

  def current(_organization_id, nil, _agent_id, _installation_id, _source_id),
    do: {:error, :authority_unavailable}

  def current(organization_id, key_id, agent_id, installation_id, source_id) do
    key =
      IntakeApiKey
      |> where([key], key.organization_id == ^organization_id and key.id == ^key_id)
      |> lock("FOR SHARE")
      |> Repo.one()

    agent =
      Agent
      |> where([agent], agent.organization_id == ^organization_id and agent.id == ^agent_id)
      |> lock("FOR SHARE")
      |> Repo.one()

    source =
      Source
      |> where([source], source.organization_id == ^organization_id and source.id == ^source_id)
      |> lock("FOR SHARE")
      |> Repo.one()

    validate(key, agent, installation_id, source)
  end

  defp validate(
         %{status: "active"} = key,
         %{status: "active"} = agent,
         installation_id,
         %{
           status: "active"
         } = source
       )
       when agent.installation_id == installation_id and not is_nil(installation_id) do
    if source.id == agent.source_id or source.agent_id == agent.id,
      do: {:ok, %{key: key, agent: agent, source: source}},
      else: {:error, :source_not_owned}
  end

  defp validate(_key, _agent, _installation_id, _source), do: {:error, :authority_unavailable}
end
