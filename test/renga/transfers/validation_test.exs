defmodule Renga.Transfers.ValidationTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Transfers.Archive
  alias Renga.Transfers.Archive.Writer
  alias Renga.Transfers.Export
  alias Renga.Transfers.Validation

  @moduletag :tmp_dir

  setup do
    %{organization: organization, scope: owner, system_scope: system_scope} =
      job_organization_fixture()

    agent = agent_fixture(organization)
    reported_resource_fixture(organization, agent)
    target_binding_fixture(organization, agent)
    {:ok, _job} = Jobs.create_job(owner, agent.id, "inventory.collect@1", %{})

    {:ok, _loose} =
      Inventory.create_observation(system_scope, agent.source_id, %{
        observation_id: "loose",
        observed_at: Renga.Time.utc_now_ms(),
        payload: %{"hostname" => "loose"}
      })

    other = Renga.InventoryFixtures.organization_fixture()

    {:ok, other_resource} =
      Inventory.create_resource(Accounts.scope_for(other), %{
        kind: "server",
        name: "other-organization",
        lifecycle_state: "active"
      })

    %{organization: organization, other_resource: other_resource}
  end

  defp export(context, parts \\ []) do
    path = Path.join(context.tmp_dir, "export-#{System.unique_integer([:positive])}.tar.zst")
    assert {:ok, _summary} = Export.write(context.organization, path, parts: parts)
    open(context, path)
  end

  defp open(context, path) do
    assert {:ok, archive} = Archive.open(path, tmp_dir: context.tmp_dir)
    on_exit(fn -> Archive.close(archive) end)
    archive
  end

  # Writes a copy of `archive` with each record type's records passed
  # through `fun`, which returns the new records or `:drop`, plus `extra`
  # record types.
  defp rewrite(context, archive, fun, extra \\ %{}) do
    writer = Writer.new(tmp_dir: context.tmp_dir)

    writer =
      archive
      |> Archive.record_types()
      |> Enum.reduce(writer, fn type, writer ->
        case fun.(type, Enum.to_list(Archive.records(archive, type))) do
          :drop -> writer
          records -> Writer.add_records(writer, type, records)
        end
      end)

    writer =
      Enum.reduce(extra, writer, fn {type, records}, w -> Writer.add_records(w, type, records) end)

    %{"organization" => organization, "snapshot_at" => snapshot_at, "parts" => parts} =
      archive.manifest

    {:ok, snapshot_at, 0} = DateTime.from_iso8601(snapshot_at)
    path = Path.join(context.tmp_dir, "rewritten-#{System.unique_integer([:positive])}.tar.zst")

    :ok =
      Writer.finish(
        writer,
        %{
          organization: %{
            id: organization["id"],
            slug: organization["slug"],
            name: organization["name"]
          },
          snapshot_at: snapshot_at,
          parts: parts
        },
        path
      )

    open(context, path)
  end

  defp change_first(archive, context, type, fun) do
    rewrite(context, archive, fn
      ^type, [first | rest] -> [fun.(first) | rest]
      _type, records -> records
    end)
  end

  defp messages(archive, opts \\ []) do
    assert {:error, problems} = Validation.validate(archive, opts)
    Enum.map(problems, &{&1.file, &1.line, &1.message})
  end

  test "an export validates, with and without its optional parts", context do
    assert :ok = context |> export() |> Validation.validate()
    assert :ok = context |> export(~w(history raw_observations)) |> Validation.validate()
  end

  test "a record must have its type's fields, each of its column's type", context do
    archive =
      context
      |> export()
      |> change_first(context, "resources", fn resource ->
        resource
        |> Map.delete("name")
        |> Map.merge(%{
          "colour" => "blue",
          "kind" => nil,
          "generation" => "two",
          "labels" => [],
          "inserted_at" => "yesterday",
          "owner_team_id" => "not-a-uuid"
        })
      end)

    assert messages(archive) == [
             {"resources.ndjson", 1, ~s(has a field "colour" its record type does not have)},
             {"resources.ndjson", 1, ~s(is missing field "name")},
             {"resources.ndjson", 1, ~s(field "kind" must have a value)},
             {"resources.ndjson", 1, ~s(field "generation" must be an integer in range)},
             {"resources.ndjson", 1, ~s(field "inserted_at" must be an ISO 8601 timestamp)},
             {"resources.ndjson", 1, ~s(field "owner_team_id" must be a UUID)}
           ]
  end

  test "values are checked against each column type", context do
    archive =
      rewrite(context, export(context), fn
        "agents", [agent | rest] ->
          [%{agent | "capabilities" => ["inventory.collect@1", 1], "metadata" => [1, nil]} | rest]

        "observations", [observation | rest] ->
          [%{observation | "reported_from" => "192.0.2.300", "payload_digest" => "%%"} | rest]

        _type, records ->
          records
      end)

    assert messages(archive) == [
             {"agents.ndjson", 1, ~s(field "capabilities" must be a list, each item a string)},
             {"observations.ndjson", 1, ~s(field "payload_digest" must be base64)},
             {"observations.ndjson", 1, ~s(field "reported_from" must be an IP address)}
           ]
  end

  test "values must be ones PostgreSQL would store in their column", context do
    at = "2026-10-22T19:00:00.000000Z"

    occupancy = fn units ->
      %{
        "id" => Ecto.UUID.generate(),
        "current_placement_id" => Ecto.UUID.generate(),
        "rack_id" => Ecto.UUID.generate(),
        "face" => "front",
        "units" => units,
        "inserted_at" => at,
        "updated_at" => at
      }
    end

    prefix = fn cidr ->
      %{
        "id" => Ecto.UUID.generate(),
        "resource_id" => Ecto.UUID.generate(),
        "prefix" => cidr,
        "status" => "active",
        "description" => nil,
        "metadata" => %{},
        "inserted_at" => at,
        "updated_at" => at,
        "vrf_id" => nil,
        "strict" => false
      }
    end

    archive =
      rewrite(context, export(context), fn
        "rack_occupancies", [] ->
          Enum.map(
            ~w|[-,) [2147483648,) [5,2) [1,2147483647] (2147483647,)
               [1,3) empty (,4] [5,5) (2147483647,2147483647)|,
            occupancy
          )

        "prefixes", [] ->
          Enum.map(
            ~w(192.0.2.1/24 2001:db8::1/64 192.0.2.0/+24 0.0.0.0/-0 2001:db8::/064
               192.0.2.0/24 2001:db8::/64 192.0.2.0/024),
            prefix
          )

        "resources", [resource | rest] ->
          # 255 characters as people read them, 510 as PostgreSQL counts.
          resource = %{
            resource
            | "name" => String.duplicate("e\u0301", 255),
              "display_name" => "a\u0000b",
              "labels" => %{"x\u0000" => "y"},
              "annotations" => %{
                "n" => %Decimal{coef: 1, exp: 131_072},
                "ok" => %Decimal{coef: 1, exp: 131_071}
              }
          }

          [resource | rest]

        "organization", [organization] ->
          # numeric(4,3): 9.9995 rounds to 10.000, which needs two digits.
          [%{organization | "default_power_factor" => Decimal.new("9.9995")}]

        _type, records ->
          records
      end)

    type_messages =
      archive
      |> messages()
      |> Enum.filter(fn {_file, _line, message} ->
        message =~ ~r/must be|longer than|cannot store|does not fit/
      end)
      |> Enum.sort()

    assert type_messages == [
             {"organization.ndjson", 1,
              ~s(field "default_power_factor" does not fit numeric\(4,3\))},
             {"prefixes.ndjson", 1, ~s(field "prefix" must be an IP network)},
             {"prefixes.ndjson", 2, ~s(field "prefix" must be an IP network)},
             {"prefixes.ndjson", 3, ~s(field "prefix" must be an IP network)},
             {"prefixes.ndjson", 4, ~s(field "prefix" must be an IP network)},
             {"prefixes.ndjson", 5, ~s(field "prefix" must be an IP network)},
             {"rack_occupancies.ndjson", 1, ~s(field "units" must be an integer range)},
             {"rack_occupancies.ndjson", 2, ~s(field "units" must be an integer range)},
             {"rack_occupancies.ndjson", 3, ~s(field "units" must be an integer range)},
             {"rack_occupancies.ndjson", 4, ~s(field "units" must be an integer range)},
             {"rack_occupancies.ndjson", 5, ~s(field "units" must be an integer range)},
             {"resources.ndjson", 1,
              ~s(field "annotations" holds a NUL character or a number PostgreSQL cannot store)},
             {"resources.ndjson", 1,
              ~s(field "display_name" contains a NUL character, which PostgreSQL cannot store)},
             {"resources.ndjson", 1,
              ~s(field "labels" holds a NUL character or a number PostgreSQL cannot store)},
             {"resources.ndjson", 1, ~s(field "name" is longer than 255 characters)}
           ]
  end

  test "no two records of a type share an ID", context do
    archive =
      rewrite(context, export(context), fn
        "resources", [first | rest] -> [first | rest] ++ [first]
        _type, records -> records
      end)

    count = archive |> Archive.records("resources") |> Enum.count()

    assert messages(archive) == [{"resources.ndjson", count, "has the same ID as line 1"}]
  end

  test "references must resolve inside the archive", context do
    %{other_resource: other_resource} = context
    missing = Ecto.UUID.generate()

    archive =
      rewrite(context, export(context), fn
        "installation_keys", [first | rest] ->
          [%{first | "agent_id" => missing} | rest]

        # Another organization's resource is as absent as a made-up one, and
        # the second claim's observation exists, but under another source.
        "resource_identifier_claims", [first, second | rest] ->
          [%{first | "resource_id" => other_resource.id}, %{second | "source_id" => missing}] ++
            rest

        _type, records ->
          records
      end)

    messages = messages(archive)
    [_first, claim | _rest] = Enum.to_list(Archive.records(archive, "resource_identifier_claims"))

    assert Enum.sort(messages) ==
             Enum.sort([
               {"installation_keys.ndjson", 1,
                ~s(field "agent_id" refers to agents record #{missing}, which the archive does not hold)},
               {"resource_identifier_claims.ndjson", 1,
                ~s(field "resource_id" refers to resources record #{other_resource.id}, which the archive does not hold)},
               {"resource_identifier_claims.ndjson", 2,
                ~s(field "source_id" refers to sources record #{missing}, which the archive does not hold)},
               {"resource_identifier_claims.ndjson", 2,
                ~s|fields "observation_id" and "source_id" (#{claim["observation_id"]}, #{missing}) match no observations record the archive holds|}
             ])
  end

  test "people are referred to only through principals", context do
    archive =
      rewrite(context, export(context), fn
        "principals", _principals -> []
        _type, records -> records
      end)

    assert Enum.any?(
             messages(archive),
             &match?(
               {"organization_memberships.ndjson", 1,
                ~s(field "user_id" refers to principal ) <> _},
               &1
             )
           )
  end

  test "the archive holds exactly the record files its parts call for", context do
    archive =
      rewrite(
        context,
        export(context),
        fn
          "cables", _records -> :drop
          _type, records -> records
        end,
        %{"secrets" => [%{"id" => Ecto.UUID.generate()}]}
      )

    assert messages(archive) == [
             {"cables.ndjson", nil, "is missing"},
             {"secrets.ndjson", nil, "is not a record type of this export"}
           ]
  end

  test "the organization record matches the manifest", context do
    archive =
      context
      |> export()
      |> change_first(context, "organization", &Map.put(&1, "name", "Someone else"))

    assert messages(archive) == [
             {"organization.ndjson", 1,
              ~s(field "name" does not match the manifest's organization)}
           ]
  end

  test "problems are listed up to the limit", context do
    archive =
      rewrite(context, export(context), fn
        "principals", principals -> Enum.map(principals, &Map.put(&1, "id", "nope"))
        "resources", resources -> Enum.map(resources, &Map.put(&1, "id", "nope"))
        _type, records -> records
      end)

    assert [_first, _second, {nil, nil, "more problems were found but not listed"}] =
             messages(archive, max_problems: 3)
  end
end
