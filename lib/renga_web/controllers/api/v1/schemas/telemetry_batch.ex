defmodule RengaWeb.Api.V1.Schemas.TelemetryBatch do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  alias Renga.Telemetry.Payload

  def json_schema do
    contract = Payload.contract()

    %{
      title: "TelemetryBatch",
      description:
        "A versioned batch of timed readings (RFD 10, \"Measured history\"), apart from " <>
          "inventory observations. Accepting one never renews the installation's lease, " <>
          "advances an inventory clock, or triggers reconciliation; the installation must " <>
          "have checked in first. The encoded body must be at most " <>
          "#{contract.max_batch_bytes} bytes.",
      type: :object,
      properties: %{
        version: %{type: :integer, enum: contract.versions},
        replay_id: %{
          type: :string,
          minLength: 1,
          description:
            "Chosen by the agent and unique per source. Resending the same batch under it " <>
              "is a duplicate; a different batch under it is a conflict. Must not be " <>
              "blank; at most #{contract.max_replay_id_length} characters."
        },
        collector: %{
          type: [:object, :null],
          description:
            "The collector module whose readings these are, resolved to its stream as an " <>
              "observation's collector is. Omitted for the installation's own host readings.",
          properties: %{
            id: %{
              type: :string,
              minLength: 1,
              description:
                "The stable collector ID from the agent configuration, as for observations."
            },
            kind: %{type: :string, enum: contract.collector_kinds}
          },
          required: [:id, :kind]
        },
        samples: %{
          type: :array,
          minItems: 1,
          maxItems: contract.max_samples,
          items: sample(contract)
        }
      },
      required: [:version, :replay_id, :samples]
    }
  end

  defp sample(contract) do
    units =
      contract.units
      |> Enum.sort()
      |> Enum.map_join(", ", fn {quantity, unit} -> "`#{quantity}` in `#{unit}`" end)

    %{
      type: :object,
      description:
        "One reading. Its series is the source's target, sensor, boundary, quantity, and " <>
          "window length; a series keeps the sample with the latest `event_at`, so a late " <>
          "replay never replaces a newer value. A sample whose `event_at` or window end is " <>
          "more than 5 minutes in the future is rejected. A well-formed sample that is not " <>
          "usable (`status` other than `valid`, a unit that does not fit its quantity, a " <>
          "negative value, or a power factor outside (0, 1]) is kept as invalid evidence, " <>
          "never as zero.",
      properties: %{
        target:
          nullable(%{
            type: :string,
            minLength: 1,
            description:
              "The collector target the reading is about, such as a PDU's address. Required " <>
                "for a collector's readings and absent for the host's own. Must not be " <>
                "blank; at most #{contract.max_name_length} characters."
          }),
        sensor: %{
          type: :string,
          minLength: 1,
          description:
            "The sensor's stable identifier within its target, such as `outlet/3`. Must not " <>
              "be blank; at most #{contract.max_name_length} characters."
        },
        component:
          nullable(%{
            type: :object,
            description:
              "The power port or outlet on the target the sensor measures, by the name the " <>
                "target's hardware type gives it. Must not be blank; at most " <>
                "#{contract.max_name_length} characters.",
            properties: %{
              kind: %{type: :string, enum: contract.component_kinds},
              name: %{type: :string, minLength: 1}
            },
            required: [:kind, :name]
          }),
        boundary: %{type: :string, enum: contract.boundaries},
        leg: %{
          type: [:string, :null],
          enum: contract.legs ++ [nil],
          description: "The three-phase leg. Required for, and allowed only on, `leg` readings."
        },
        quantity: %{type: :string, enum: contract.quantities},
        unit: %{
          type: [:string, :null],
          description:
            "Usable only as #{units}; `state` takes none. At most " <>
              "#{contract.max_unit_length} characters."
        },
        value: %{type: [:number, :null], description: "The reading of a numeric quantity."},
        state: %{
          type: [:string, :null],
          description:
            "The reading of a `state` quantity, such as `on` or `failed`. At most " <>
              "#{contract.max_state_length} characters."
        },
        status: %{
          type: [:string, :null],
          enum: contract.statuses ++ [nil],
          description: "`valid` when omitted. A missing or failed reading carries no value."
        },
        origin: %{
          type: [:string, :null],
          enum: contract.origins ++ [nil],
          description:
            "`native` (the default) for the agent's own reading, `exporter` for one mapped " <>
              "from a local Prometheus exporter."
        },
        coverage: %{
          type: [:string, :null],
          enum: contract.coverages ++ [nil],
          description:
            "For an aggregate, whether it covers everything at its boundary. An undeclared " <>
              "coverage is unknown."
        },
        window: %{
          type: :object,
          description: "The sampling window. An instantaneous reading starts and ends at once.",
          properties: %{
            start: iso8601_timestamp(),
            end: iso8601_timestamp("Not before `start`.")
          },
          required: [:start, :end]
        },
        event_at: iso8601_timestamp("When the reading was taken."),
        mapping: %{
          type: :object,
          description: "The source mapping that produced the reading.",
          properties: %{
            name: %{
              type: :string,
              minLength: 1,
              description: "Must not be blank; at most #{contract.max_name_length} characters."
            },
            version: %{type: :integer, minimum: 1, maximum: contract.max_mapping_version}
          },
          required: [:name, :version]
        },
        fresh_for_seconds: %{
          type: :integer,
          minimum: 1,
          maximum: contract.max_freshness_seconds,
          description:
            "How long after `event_at` the reading stays current, as its mapping declares."
        }
      },
      required: [
        :sensor,
        :boundary,
        :quantity,
        :window,
        :event_at,
        :mapping,
        :fresh_for_seconds
      ]
    }
  end
end
