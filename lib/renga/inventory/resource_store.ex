defmodule Renga.Inventory.ResourceStore do
  @moduledoc false

  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceRevision
  alias Renga.Repo

  @resource_revision_lock_key 1_380_271_687

  # Callers own the surrounding domain transaction. Keeping envelope and
  # revision persistence here gives every context the same global watch cursor.
  def insert(organization_id, attrs) do
    revision = next_revision!()

    with {:ok, resource} <-
           %Resource{organization_id: organization_id}
           |> Resource.changeset(attrs)
           |> Ecto.Changeset.put_change(:resource_version, revision)
           |> Repo.insert(),
         {:ok, _resource_revision} <- insert_revision(resource, revision) do
      {:ok, resource}
    end
  end

  def next_revision! do
    # Hold allocation order until commit so a watch cursor cannot pass an
    # earlier revision that is still invisible in another transaction.
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@resource_revision_lock_key])
    %{rows: [[revision]]} = Repo.query!("SELECT nextval('resource_revision_sequence')")
    revision
  end

  defp insert_revision(resource, revision) do
    %ResourceRevision{
      organization_id: resource.organization_id,
      resource_id: resource.id
    }
    |> ResourceRevision.changeset(%{
      revision: revision,
      action: "created",
      generation: resource.generation,
      snapshot: snapshot(resource)
    })
    |> Repo.insert()
  end

  defp snapshot(resource) do
    %{
      "id" => resource.id,
      "kind" => resource.kind,
      "name" => resource.name,
      "display_name" => resource.display_name,
      "lifecycle_state" => resource.lifecycle_state,
      "spec" => resource.spec,
      "generation" => resource.generation,
      "resource_version" => resource.resource_version,
      "labels" => resource.labels,
      "annotations" => resource.annotations,
      "deletion_requested_at" => resource.deletion_requested_at
    }
  end
end
