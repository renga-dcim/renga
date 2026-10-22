defmodule Renga.Jobs.QueryTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias Renga.Jobs.Capability
  alias Renga.Jobs.Queries
  alias Renga.Jobs.Query
  alias Renga.Jobs.Query.Schema
  alias Renga.Jobs.Registry

  @queries %{
    "query.listening_sockets@1" => {Queries.ListeningSockets, :sensitive},
    "query.services@1" => {Queries.Services, :sensitive},
    "query.disk_usage@1" => {Queries.DiskUsage, :inventory},
    "query.routes@1" => {Queries.Routes, :inventory},
    "query.time_sync@1" => {Queries.TimeSync, :inventory},
    "query.packages@1" => {Queries.Packages, :sensitive},
    "query.sql@1" => {Queries.Sql, :sensitive}
  }

  # The queries whose parameters are typed values rather than request text.
  @named_queries Map.delete(@queries, "query.sql@1")

  # One conforming result per query, the shape the agent reports.
  @results %{
    Queries.ListeningSockets => %{
      "sockets" => [
        %{
          "protocol" => "tcp",
          "address" => "0.0.0.0",
          "port" => 22,
          "process" => "sshd",
          "pid" => 812
        },
        %{"protocol" => "udp", "address" => "::", "port" => 53, "process" => nil, "pid" => nil}
      ],
      "truncated" => false
    },
    Queries.Services => %{
      "units" => [
        %{
          "name" => "sshd.service",
          "description" => "OpenSSH server daemon",
          "load_state" => "loaded",
          "active_state" => "failed",
          "sub_state" => "failed",
          "enabled_state" => "enabled"
        }
      ],
      "truncated" => false
    },
    Queries.DiskUsage => %{
      "filesystems" => [
        %{
          "mount_point" => "/",
          "device" => "/dev/sda1",
          "fs_type" => "ext4",
          "size_bytes" => 100,
          "used_bytes" => 40,
          "available_bytes" => 55,
          "inodes_total" => 10,
          "inodes_used" => 2
        }
      ],
      "truncated" => false
    },
    Queries.Routes => %{
      "routes" => [
        %{
          "table" => 254,
          "vrf" => nil,
          "family" => "ipv4",
          "destination" => "0.0.0.0/0",
          "gateway" => "192.0.2.1",
          "interface" => "eth0",
          "metric" => 100,
          "protocol" => "dhcp"
        }
      ],
      "truncated" => false
    },
    Queries.TimeSync => %{
      "synchronized" => true,
      "daemon" => "chronyd",
      "source" => "time.example.net",
      "stratum" => 2,
      "offset_us" => -42,
      "max_error_us" => 1200,
      "estimated_error_us" => 300
    },
    Queries.Packages => %{
      "packages" => [
        %{
          "name" => "openssl",
          "version" => "3.0.13-0ubuntu3",
          "architecture" => "amd64",
          "manager" => "dpkg"
        }
      ],
      "truncated" => true
    },
    Queries.Sql => %{
      "columns" => ["name", "pid"],
      "rows" => [["sshd", "812"], ["chronyd", ""]],
      "truncated" => false
    }
  }

  test "the queries are registered with RFD 12's sensitivities" do
    assert Enum.sort(Query.keys()) == @queries |> Map.keys() |> Enum.sort()

    for {key, {module, sensitivity}} <- @queries do
      assert {:ok, ^module} = Registry.fetch(key)
      assert Capability.key(module) == key
      assert module.sensitivity() == sensitivity
      assert module.risk_class() == :observe
      assert module.retry_class() == :idempotent
      assert module.sensitive_output?()
      refute module.allowed_by_default?()
      assert module.output_limit_bytes() == 64 * 1024
      assert module.timeout_ms() in [:timer.seconds(30), :timer.seconds(60)]
      assert module.summary() =~ ~r/^\S/
    end
  end

  test "inventory queries need queries.run and sensitive ones queries.run_sensitive too" do
    assert Queries.DiskUsage.required_permissions() == ["queries.run"]

    assert Queries.Packages.required_permissions() ==
             ["queries.run", "queries.run_sensitive"]

    assert Renga.Jobs.Capabilities.InventoryCollect.required_permissions() == ["jobs.request"]
    refute Query.query?(Renga.Jobs.Capabilities.InventoryCollect)
  end

  test "each query accepts its own result and describes it" do
    for {module, result} <- @results do
      changeset = module.result_changeset(result)
      assert changeset.valid?, "#{inspect(module)}: #{inspect(changeset.errors)}"
      assert {:ok, applied} = Changeset.apply_action(changeset, :validate)
      assert applied |> Renga.JSON.encode!() |> Renga.JSON.decode!() == result
      assert module.describe_result(result) =~ ~r/^\S/
    end
  end

  test "one item reads in the singular" do
    assert Queries.DiskUsage.describe_result(%{"filesystems" => [%{}]}) == "1 filesystem"
    assert Queries.ListeningSockets.describe_result(%{"sockets" => [%{}]}) == "1 listening socket"
    assert Queries.Packages.describe_result(%{"packages" => [%{}]}) == "1 package"
    assert Queries.Routes.describe_result(%{"routes" => [%{}]}) == "1 route"
    assert Queries.Services.describe_result(%{"units" => [%{}]}) == "1 unit, 0 failed"
    assert Queries.Services.describe_result(%{"units" => []}) == "0 units, 0 failed"
  end

  test "parameters are typed, and no named query takes a command, path, or script" do
    assert Queries.DiskUsage.parameters_changeset(%{}).valid?
    refute Queries.DiskUsage.parameters_changeset(%{"command" => "rm -rf /"}).valid?
    assert Queries.ListeningSockets.parameters_changeset(%{"port" => 23}).valid?
    refute Queries.ListeningSockets.parameters_changeset(%{"port" => 0}).valid?
    refute Queries.ListeningSockets.parameters_changeset(%{"port" => "23"}).valid?
    assert Queries.Routes.parameters_changeset(%{"family" => "ipv6"}).valid?
    refute Queries.Routes.parameters_changeset(%{"family" => "ipx"}).valid?
    assert Queries.Packages.parameters_changeset(%{"name" => "openssl"}).valid?
    refute Queries.Packages.parameters_changeset(%{"name" => String.duplicate("a", 129)}).valid?
    assert Queries.Services.parameters_changeset(%{"failed_only" => true}).valid?

    for {_key, {module, _sensitivity}} <- @named_queries,
        {name, type, _required?} <- Query.parameter_fields(module) do
      refute name in ~w(command cmd path script exec args sql), "#{inspect(module)}: #{name}"

      assert match?({:integer, _}, type) or match?({:enum, _}, type) or type == :boolean or
               match?({:string, max: max} when max <= 128, type)
    end
  end

  test "ad hoc SQL is sensitive, needs text, and returns a bounded table" do
    assert Queries.Sql.required_permissions() == ["queries.run", "queries.run_sensitive"]
    refute Queries.Sql.allowed_by_default?()
    assert Queries.Sql.parameters_changeset(%{"sql" => "SELECT name FROM processes"}).valid?
    refute Queries.Sql.parameters_changeset(%{"sql" => ""}).valid?
    refute Queries.Sql.parameters_changeset(%{}).valid?
    refute Queries.Sql.parameters_changeset(%{"sql" => String.duplicate("x", 4097)}).valid?
    refute Queries.Sql.parameters_changeset(%{"sql" => "SELECT 1", "table" => "file"}).valid?

    refute Queries.Sql.result_changeset(%{
             "columns" => ["a"],
             "rows" => [[1]],
             "truncated" => false
           }).valid?

    assert Queries.Sql.describe_result(%{"rows" => [["a"]]}) == "1 row"
  end

  # The agent's tests read the committed copy, so it must match the code.
  test "priv/queries/v1.json is the current contract" do
    if File.read!(Query.contract_path()) != Query.contract_json() do
      flunk("priv/queries/v1.json is out of date; regenerate it with `mix queries.contract`")
    end
  end

  test "the contract requires what the schemas require and nothing more" do
    contract = Query.contract()

    for {module, result} <- @results do
      json_schema = contract[Capability.key(module)]["result"]
      assert json_schema["additionalProperties"] == false
      assert Schema.validate(module.result_schema(), result) == []

      for {name, _type, true} <- Schema.fields(module.result_schema()),
          do: assert(name in json_schema["required"])
    end
  end

  describe "Schema" do
    @schema {:object,
             [
               {"name", {:string, max: 4}},
               {"count", {:optional, {:integer, min: 1}}},
               {"tags", {:list, {:enum, ~w(a b)}, max: 2}},
               {"items", {:list, {:object, [{"id", {:nullable, :integer}}]}, max: 3}}
             ]}

    test "accepts conforming values" do
      value = %{"name" => "abcd", "tags" => ["a"], "items" => [%{"id" => nil}, %{"id" => 1}]}
      assert Schema.validate(@schema, value) == []
      assert Schema.changeset(@schema, value).valid?
    end

    test "names every violation with its path" do
      value = %{
        "name" => "abcde",
        "count" => 0,
        "tags" => ["a", "c"],
        "items" => [%{"id" => "1"}, %{"id" => 2, "extra" => true}],
        "rogue" => 1
      }

      assert Schema.validate(@schema, value) == [
               {["rogue"], "is not a known field"},
               {["name"], "must be at most 4 characters"},
               {["count"], "must be at least 1"},
               {["tags", 1], "must be one of a, b"},
               {["items", 0, "id"], "must be an integer"},
               {["items", 1, "extra"], "is not a known field"}
             ]

      errors = Schema.changeset(@schema, value).errors
      assert {:base, {"rogue is not a known field", []}} in errors
      assert {:items, {"[0].id must be an integer", []}} in errors
    end

    test "requires fields unless optional and bounds lists" do
      assert [{["name"], "can't be blank"}, {["tags"], "can't be blank"}, {["items"], _}] =
               Schema.validate(@schema, %{})

      assert [{["tags"], "must have at most 2 items"}] =
               Schema.validate(@schema, %{"name" => "a", "tags" => ~w(a a a), "items" => []})

      refute Schema.changeset(@schema, "not a map").valid?
    end

    test "keeps a required field given as null" do
      schema = {:object, [{"offset", {:nullable, :integer}}, {"ok", :boolean}]}

      assert {:ok, %{offset: nil, ok: false}} =
               schema
               |> Schema.changeset(%{"offset" => nil, "ok" => false})
               |> Changeset.apply_action(:validate)
    end

    test "counts a string's characters as code points, bounded by its bytes" do
      schema = {:object, [{"name", {:string, max: 4}}]}

      # Four precomposed and four decomposed é: 4 and 8 code points.
      assert Schema.validate(schema, %{"name" => String.duplicate("\u00e9", 4)}) == []

      assert [{["name"], "must be at most 4 characters"}] =
               Schema.validate(schema, %{"name" => String.duplicate("e\u0301", 4)})

      # One grapheme, but far more bytes than four code points can take.
      assert [{["name"], "must be at most 4 characters"}] =
               Schema.validate(schema, %{"name" => "a" <> String.duplicate("\u0301", 100_000)})
    end

    test "bounds strings from below when asked" do
      assert [{[], "must be at least 2 characters"}] = Schema.validate({:string, min: 2}, "a")
      assert Schema.validate({:string, min: 2}, "ab") == []

      assert Schema.to_json_schema({:string, min: 2, max: 3}) ==
               %{"type" => "string", "minLength" => 2, "maxLength" => 3}

      assert Schema.to_json_schema({:string, max: 3}) == %{"type" => "string", "maxLength" => 3}
    end
  end
end
