defmodule Renga.Inventory.ResourceStore do
  @moduledoc false

  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceRevision
  alias Renga.Repo

  # Before RFD 21 every allocation took this one bigint advisory lock
  # exclusively. Allocations now take it shared, so they do not wait on each
  # other, and an older node or a migration still taking it exclusively cannot
  # run alongside them: during a rolling deploy, old and new allocators exclude
  # each other instead of committing one organization's revisions out of
  # order. While an exclusive request is held or queued, new allocators in
  # every organization wait behind it.
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
    # Outside a transaction each lock would be released before the revision
    # is even allocated.
    unless Repo.in_transaction?() do
      raise ArgumentError, "resource revision allocation requires an enclosing transaction"
    end

    Repo.query!("SELECT pg_advisory_xact_lock_shared($1)", [@legacy_revision_lock_key])

    Repo.query!(
      "SELECT pg_advisory_xact_lock($1, hashtext($2::text))",
      revision_lock_args(organization_id)
    )

    %{rows: [[revision]]} = Repo.query!("SELECT nextval('resource_revision_sequence')")
    revision
  end

  @doc """
  Allocates `count` revisions for `organization_id` at once, in increasing
  order, under the same locks as `next_revision!/1`. An import (RFD 20)
  maps the source's revisions onto them in order. Other organizations do
  not wait: the sequence never blocks, and their locks are their own.
  """
  def allocate_revisions!(organization_id, 0) when is_binary(organization_id), do: []

  def allocate_revisions!(organization_id, count)
      when is_binary(organization_id) and is_integer(count) and count > 0 do
    first = next_revision!(organization_id)

    %{rows: rows} =
      Repo.query!(
        "SELECT nextval('resource_revision_sequence') FROM generate_series(1, $1)",
        [count - 1]
      )

    Enum.sort([first | Enum.map(rows, fn [revision] -> revision end)])
  end

  @doc """
  The SQL arguments of `organization_id`'s revision lock,
  `pg_advisory_xact_lock($1, hashtext($2::text))`, also for tests that check
  lock ordering. The ID is canonicalized so that every spelling of it takes
  the same lock.
  """
  def revision_lock_args(organization_id),
    do: [@organization_revision_lock_namespace, Ecto.UUID.cast!(organization_id)]

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
