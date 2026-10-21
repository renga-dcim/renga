defmodule Renga.Inventory.ResourceStore do
  @moduledoc false

  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceRevision
  alias Renga.Repo

  # Before RFD 21 every allocation took this one bigint advisory lock
  # exclusively. Allocations now take it shared, so they never wait on each
  # other, and an older node still taking it exclusively cannot run alongside
  # them: during a rolling deploy, old and new allocators exclude each other
  # instead of committing one organization's revisions out of order.
  @legacy_revision_lock_key 1_380_271_687
  # Namespace of the per-organization lock, in the two-int4 key space, which
  # never overlaps the single-bigint key space above.
  @organization_revision_lock_namespace 1_380_271_687

  # Callers own the surrounding domain transaction. Keeping envelope and
  # revision persistence here gives every context the same watch cursor.
  def insert(organization_id, attrs) do
    revision = next_revision!(organization_id)

    with {:ok, resource} <-
           %Resource{organization_id: organization_id}
           |> Resource.changeset(attrs)
           |> Ecto.Changeset.put_change(:resource_version, revision)
           |> Repo.insert(),
         {:ok, _resource_revision} <- insert_revision(resource, revision, "created") do
      {:ok, resource}
    end
  end

  def update(%Resource{} = resource, attrs) do
    revision = next_revision!(resource.organization_id)

    with {:ok, updated} <-
           resource
           |> Resource.changeset(attrs)
           |> Ecto.Changeset.put_change(:resource_version, revision)
           |> Repo.update(),
         {:ok, _resource_revision} <-
           insert_revision(updated, revision, revision_action(resource, updated)) do
      {:ok, updated}
    end
  end

  @doc """
  Allocates the next resource revision for a write in `organization_id`.

  The lock is held until commit so a watch cursor cannot pass an earlier
  revision that is still invisible in another transaction. Every such reader
  is scoped to one organization, so the order only has to hold within an
  organization, and writes in different organizations do not wait on each
  other (RFD 21). The sequence stays global, so revisions remain unique and
  increasing within each organization but say nothing about order across
  organizations.
  """
  def next_revision!(organization_id) when is_binary(organization_id) do
    Repo.query!("SELECT pg_advisory_xact_lock_shared($1)", [@legacy_revision_lock_key])

    Repo.query!("SELECT pg_advisory_xact_lock($1, hashtext($2::text))", [
      @organization_revision_lock_namespace,
      organization_id
    ])

    %{rows: [[revision]]} = Repo.query!("SELECT nextval('resource_revision_sequence')")
    revision
  end

  @doc """
  The SQL arguments of `organization_id`'s revision lock, for tests that
  check lock ordering: `pg_try_advisory_xact_lock($1, hashtext($2::text))`.
  """
  def revision_lock_args(organization_id),
    do: [@organization_revision_lock_namespace, organization_id]

  defp insert_revision(resource, revision, action) do
    %ResourceRevision{
      organization_id: resource.organization_id,
      resource_id: resource.id
    }
    |> ResourceRevision.changeset(%{
      revision: revision,
      action: action,
      generation: resource.generation,
      snapshot: snapshot(resource)
    })
    |> Repo.insert()
  end

  defp revision_action(
         %Resource{deletion_requested_at: nil},
         %Resource{deletion_requested_at: deletion_requested_at}
       )
       when not is_nil(deletion_requested_at),
       do: "deletion_requested"

  defp revision_action(%Resource{}, %Resource{}), do: "updated"

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
