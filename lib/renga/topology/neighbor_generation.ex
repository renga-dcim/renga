defmodule Renga.Topology.NeighborGeneration do
  @moduledoc """
  Durable expiry at a fixed input version and server time. Each call commits
  one match/selection batch or one endpoint's findings; only the final pointer
  switch changes current topology. Database triggers fence old and new writers.
  """
  import Ecto.Query
  alias Renga.{Authorization, Repo}
  alias Renga.Inventory.Interface

  alias Renga.Topology.{
    CableReconciler,
    InterfaceNeighborEvidence,
    InterfaceNeighborMatch,
    NeighborReconciler,
    TopologyFinding
  }

  def step(scope, as_of, options \\ []) do
    Repo.with_statement_timeout(200, fn _ ->
      Authorization.authorize_system!(scope, "topology_reconciler")
      CableReconciler.lock_state!(scope.organization_id)
      org = Ecto.UUID.dump!(scope.organization_id)

      Repo.query!(
        "INSERT INTO neighbor_generation_heads(organization_id) VALUES ($1) ON CONFLICT DO NOTHING",
        [org]
      )

      %{rows: [[version]]} =
        Repo.query!(
          "SELECT version FROM neighbor_generation_heads WHERE organization_id = $1 FOR UPDATE",
          [org]
        )

      cleanup(org)

      due? =
        Repo.exists?(
          from e in InterfaceNeighborEvidence,
            where:
              e.organization_id == ^scope.organization_id and is_nil(e.stale_at) and
                e.expires_at <= ^as_of
        )

      generation =
        pending(scope.organization_id) ||
          if(due?, do: begin_generation(scope.organization_id, version, as_of))

      cond do
        is_nil(generation) ->
          :cleaned

        generation.status == "building" and generation.watermark != version ->
          Repo.query!("UPDATE neighbor_generations SET status = 'obsolete' WHERE id = $1", [
            dump(generation.id)
          ])

          :invalidated

        true ->
          Repo.query!("SELECT set_config('renga.neighbor_generation', $1, true)", [generation.id])

          result =
            if generation.status == "published",
              do: compact(generation, Keyword.get(options, :batch_size, 25)),
              else: advance(generation, Keyword.get(options, :batch_size, 10))

          if hook = options[:after_batch], do: hook.(result)
          # Failed transactions discard LOCAL settings on rollback; issuing
          # another query there would mask the original cancellation error.
          Repo.query!("SELECT set_config('renga.neighbor_generation', '', true)")
          result
      end
    end)
  end

  defp pending(org) do
    case Repo.query!(
           "SELECT id, watermark, as_of, phase, cursor, status FROM neighbor_generations WHERE organization_id = $1 AND status IN ('building','published') ORDER BY status DESC LIMIT 1 FOR UPDATE",
           [dump(org)]
         ).rows do
      [[id, version, as_of, phase, cursor, status]] ->
        %{
          id: Ecto.UUID.load!(id),
          org: org,
          watermark: version,
          as_of: DateTime.from_naive!(as_of, "Etc/UTC"),
          phase: phase,
          status: status,
          cursor: cursor && Ecto.UUID.load!(cursor)
        }

      [] ->
        nil
    end
  end

  defp begin_generation(org, version, as_of) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO neighbor_generations(id, organization_id, watermark, as_of) VALUES ($1,$2,$3,$4)",
      [dump(id), dump(org), version, as_of]
    )

    pending(org)
  end

  defp advance(%{phase: "matches"} = g, size) do
    query =
      from e in InterfaceNeighborEvidence,
        where: e.organization_id == ^g.org and is_nil(e.stale_at),
        order_by: e.id,
        limit: ^size

    query = if g.cursor, do: where(query, [e], e.id > ^g.cursor), else: query
    evidence = Repo.all(query)

    Enum.each(evidence, fn e ->
      existing =
        Repo.get_by(InterfaceNeighborMatch,
          organization_id: g.org,
          interface_neighbor_evidence_id: e.id
        )

      interface = Repo.get!(Interface, e.local_interface_id)

      if interface.status == "not_present" do
        if existing,
          do: store(g, "interface_neighbor_matches", existing.id, row(existing), deleted: true)
      else
        attrs = NeighborReconciler.expiry_match(g.org, e)

        match =
          Map.merge(
            %{
              id: (existing && existing.id) || Ecto.UUID.generate(),
              organization_id: g.org,
              interface_neighbor_evidence_id: e.id,
              inserted_at: (existing && existing.inserted_at) || g.as_of,
              updated_at: g.as_of
            },
            attrs
          )

        store(g, "interface_neighbor_matches", match.id, match)
        if attrs.status == "matched", do: candidate(g, e, attrs.remote_interface_id)
      end
    end)

    checkpoint(g, evidence, "select")
  end

  defp advance(%{phase: "select"} = g, size) do
    candidates =
      Repo.query!(
        """
        SELECT key, payload, endpoint_a, endpoint_b FROM neighbor_generation_rows
        WHERE generation_id = $1 AND kind = 'candidate' AND NOT processed
        ORDER BY reciprocal DESC, observed_at DESC, observation_id DESC, endpoint_a, endpoint_b LIMIT $2
        """,
        [dump(g.id), size]
      ).rows

    Enum.each(candidates, fn [key, candidate, a, b] ->
      a = Ecto.UUID.load!(a)
      b = Ecto.UUID.load!(b)

      %{rows: [[used]]} =
        Repo.query!(
          "SELECT EXISTS (SELECT 1 FROM neighbor_generation_rows WHERE generation_id = $1 AND kind = 'used' AND key IN ($2,$3))",
          [dump(g.id), a, b]
        )

      unless used do
        primary = Repo.get!(InterfaceNeighborEvidence, candidate["primary"])
        id = Ecto.UUID.generate()

        store(g, "current_interface_adjacencies", id, %{
          id: id,
          organization_id: g.org,
          interface_a_id: a,
          interface_b_id: b,
          primary_evidence_id: primary.id,
          confidence:
            if(candidate["a_reports"] and candidate["b_reports"],
              do: "reciprocal",
              else: "reported"
            ),
          last_observed_at: primary.observed_at,
          metadata: %{"protocols" => candidate["protocols"]},
          inserted_at: g.as_of,
          updated_at: g.as_of
        })

        store(g, "used", a, %{})
        store(g, "used", b, %{})
      end

      Repo.query!(
        "UPDATE neighbor_generation_rows SET processed = true WHERE generation_id = $1 AND kind = 'candidate' AND key = $2",
        [dump(g.id), key]
      )
    end)

    if candidates == [], do: phase(g, "findings"), else: :building
  end

  defp advance(%{phase: "findings"} = g, _size) do
    query = from i in Interface, where: i.organization_id == ^g.org, order_by: i.id, limit: 1
    query = if g.cursor, do: where(query, [i], i.id > ^g.cursor), else: query
    interfaces = Repo.all(query)

    Enum.each(interfaces, fn interface ->
      desired =
        NeighborReconciler.expiry_findings(g.org, interface.id, g.as_of, g.id) ++
          CableReconciler.expiry_findings(g.org, interface.id, g.as_of)

      kinds = NeighborReconciler.finding_kinds() ++ ["cable_neighbor_mismatch"]

      existing =
        Repo.all(
          from f in TopologyFinding,
            where:
              f.organization_id == ^g.org and f.interface_id == ^interface.id and
                f.status == "open" and f.kind in ^kinds
        )

      existing = Map.new(existing, &{{&1.kind, &1.resolution_key}, &1})

      Enum.each(desired, fn attrs ->
        previous = existing[{attrs.kind, attrs.resolution_key}]
        id = (previous && previous.id) || Ecto.UUID.generate()

        observed =
          if previous && DateTime.after?(previous.last_observed_at, attrs.last_observed_at),
            do: previous.last_observed_at,
            else: attrs.last_observed_at

        store(
          g,
          "topology_findings",
          id,
          Map.merge(attrs, %{
            id: id,
            organization_id: g.org,
            status: "open",
            resolved_at: nil,
            last_observed_at: observed,
            inserted_at: (previous && previous.inserted_at) || g.as_of,
            updated_at: g.as_of
          })
        )
      end)

      desired_keys = MapSet.new(desired, &{&1.kind, &1.resolution_key})

      for {key, previous} <- existing, not MapSet.member?(desired_keys, key) do
        resolved =
          if DateTime.after?(previous.last_observed_at, g.as_of),
            do: previous.last_observed_at,
            else: g.as_of

        store(
          g,
          "topology_findings",
          previous.id,
          Map.merge(row(previous), %{
            status: "resolved",
            resolved_at: resolved,
            updated_at: g.as_of
          })
        )
      end
    end)

    checkpoint(g, interfaces, "publish")
  end

  defp advance(%{phase: "publish"} = g, _size) do
    # The organization row and topology lock still fence every relevant input.
    # No relationship or finding is copied/deleted during this constant-size commit.
    %{num_rows: 1} =
      Repo.query!(
        "UPDATE neighbor_generation_heads SET current_generation_id = $1 WHERE organization_id = $2 AND version = $3",
        [dump(g.id), dump(g.org), g.watermark]
      )

    Repo.query!(
      "UPDATE neighbor_generations SET status = 'published', phase = 'compact_expiry', cursor = NULL WHERE id = $1",
      [dump(g.id)]
    )

    :published
  end

  # The published overlay remains authoritative during compaction. Copying
  # into storage must not count as new evidence or recursively materialize the
  # whole generation. A restart resumes this cursor, not a tenant-wide copy.
  defp compact(g, size) do
    Repo.query!("SELECT set_config('renga.neighbor_materializing', 'true', true)")
    compact_batch(g, size)
    Repo.query!("SELECT set_config('renga.neighbor_materializing', 'false', true)")
    :compacting
  end

  defp compact_batch(%{phase: "compact_expiry"} = g, size) do
    result =
      Repo.query!(
        """
        UPDATE interface_neighbor_evidence_neighbor_storage SET stale_at = expires_at, stale_reason = 'expired'
        WHERE id IN (SELECT id FROM interface_neighbor_evidence_neighbor_storage
          WHERE organization_id = $1 AND stale_at IS NULL AND expires_at <= $2 ORDER BY id LIMIT $3)
        """,
        [dump(g.org), g.as_of, size]
      )

    if result.num_rows == 0, do: phase(g, "compact_matches")
  end

  defp compact_batch(%{phase: "compact_clear"} = g, size) do
    result =
      Repo.query!(
        "DELETE FROM current_interface_adjacencies_neighbor_storage WHERE id IN (SELECT id FROM current_interface_adjacencies_neighbor_storage WHERE organization_id = $1 ORDER BY id LIMIT $2)",
        [dump(g.org), size]
      )

    if result.num_rows == 0, do: phase(g, "compact_adjacencies")
  end

  defp compact_batch(%{phase: "compact_done"} = g, _size) do
    Repo.query!(
      "UPDATE neighbor_generation_heads SET current_generation_id = NULL WHERE organization_id = $1",
      [dump(g.org)]
    )

    Repo.query!("UPDATE neighbor_generations SET status = 'obsolete' WHERE id = $1", [dump(g.id)])
  end

  defp compact_batch(g, size) do
    {kind, next} =
      case g.phase do
        "compact_matches" -> {"interface_neighbor_matches", "compact_findings"}
        "compact_findings" -> {"topology_findings", "compact_clear"}
        "compact_adjacencies" -> {"current_interface_adjacencies", "compact_done"}
      end

    rows =
      Repo.query!(
        "SELECT key, payload, deleted FROM neighbor_generation_rows WHERE generation_id = $1 AND kind = $2 AND ($3::text IS NULL OR key > $3) ORDER BY key LIMIT $4",
        [dump(g.id), kind, g.cursor, size]
      ).rows

    storage = kind <> "_neighbor_storage"

    %{rows: [[columns]]} =
      Repo.query!(
        "SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) FROM pg_attribute WHERE attrelid = $1::text::regclass AND attnum > 0 AND NOT attisdropped",
        [storage]
      )

    for [key, payload, deleted] <- rows do
      if deleted do
        Repo.query!("DELETE FROM #{storage} WHERE id = $1", [dump(key)])
      else
        Repo.query!(
          "INSERT INTO #{storage} SELECT (jsonb_populate_record(NULL::#{storage}, $1)).* ON CONFLICT (id) DO UPDATE SET (#{columns}) = (SELECT #{columns} FROM jsonb_populate_record(NULL::#{storage}, to_jsonb(EXCLUDED)))",
          [payload]
        )
      end
    end

    case List.last(rows) do
      nil ->
        phase(g, next)

      [key, _, _] ->
        Repo.query!("UPDATE neighbor_generations SET cursor = $1 WHERE id = $2", [
          dump(key),
          dump(g.id)
        ])
    end
  end

  defp candidate(g, e, remote) do
    [a, b] = Enum.sort([e.local_interface_id, remote])
    key = a <> ":" <> b

    previous =
      Repo.query!(
        "SELECT payload FROM neighbor_generation_rows WHERE generation_id = $1 AND kind = 'candidate' AND key = $2",
        [dump(g.id), key]
      ).rows

    previous =
      case previous do
        [[value]] -> value
        [] -> %{}
      end

    primary =
      if previous["primary"], do: Repo.get!(InterfaceNeighborEvidence, previous["primary"])

    primary =
      if primary &&
           NeighborReconciler.primary_evidence_order(primary) >
             NeighborReconciler.primary_evidence_order(e), do: primary, else: e

    payload = %{
      primary: primary.id,
      a_reports: previous["a_reports"] == true or e.local_interface_id == a,
      b_reports: previous["b_reports"] == true or e.local_interface_id == b,
      protocols: Enum.sort(Enum.uniq([e.protocol | previous["protocols"] || []]))
    }

    store(g, "candidate", key, payload,
      reciprocal: payload.a_reports and payload.b_reports,
      observed_at: primary.observed_at,
      observation_id: dump(primary.observation_id),
      endpoint_a: dump(a),
      endpoint_b: dump(b)
    )
  end

  defp checkpoint(g, [], next), do: phase(g, next)

  defp checkpoint(g, entries, _next) do
    Repo.query!("UPDATE neighbor_generations SET cursor = $1 WHERE id = $2", [
      dump(List.last(entries).id),
      dump(g.id)
    ])

    :building
  end

  defp phase(g, next) do
    Repo.query!("UPDATE neighbor_generations SET phase = $1, cursor = NULL WHERE id = $2", [
      next,
      dump(g.id)
    ])

    :building
  end

  defp store(g, kind, key, payload, options \\ []) do
    Repo.query!(
      """
      INSERT INTO neighbor_generation_rows(generation_id, organization_id, kind, key, payload, deleted, reciprocal, observed_at, observation_id, endpoint_a, endpoint_b)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
      ON CONFLICT (generation_id,kind,key) DO UPDATE SET payload = EXCLUDED.payload,
        deleted = EXCLUDED.deleted, reciprocal = EXCLUDED.reciprocal, observed_at = EXCLUDED.observed_at,
        observation_id = EXCLUDED.observation_id, endpoint_a = EXCLUDED.endpoint_a, endpoint_b = EXCLUDED.endpoint_b
      """,
      [
        dump(g.id),
        dump(g.org),
        kind,
        key,
        payload,
        options[:deleted] || false,
        options[:reciprocal] || false,
        options[:observed_at],
        options[:observation_id],
        options[:endpoint_a],
        options[:endpoint_b]
      ]
    )
  end

  defp cleanup(org) do
    Repo.query!(
      """
      DELETE FROM neighbor_generation_rows WHERE (generation_id,kind,key) IN
        (SELECT r.generation_id,r.kind,r.key FROM neighbor_generation_rows r JOIN neighbor_generations g ON g.id = r.generation_id
         WHERE g.organization_id = $1 AND g.status = 'obsolete' ORDER BY r.generation_id,r.kind,r.key LIMIT 100)
      """,
      [org]
    )

    Repo.query!(
      "DELETE FROM neighbor_generations WHERE id IN (SELECT g.id FROM neighbor_generations g WHERE g.organization_id = $1 AND g.status = 'obsolete' AND NOT EXISTS (SELECT 1 FROM neighbor_generation_rows r WHERE r.generation_id = g.id) LIMIT 1)",
      [org]
    )
  end

  defp row(struct), do: Map.take(struct, struct.__struct__.__schema__(:fields))
  defp dump(id), do: Ecto.UUID.dump!(id)
end
