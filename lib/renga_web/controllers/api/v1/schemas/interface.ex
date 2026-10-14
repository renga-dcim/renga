defmodule RengaWeb.Api.V1.Schemas.Interface do
  @moduledoc false

  import RengaWeb.Api.V1.Schemas

  def json_schema do
    contract = contract()
    positive_int32 = %{type: :integer, minimum: 1, maximum: contract.max_postgres_integer}

    %{
      title: "Interface",
      type: :object,
      properties: %{
        name: non_blank_string(),
        kind: %{type: :string, enum: contract.interface_kinds},
        status: %{type: :string, enum: contract.interface_statuses},
        mac_address: %{
          type: [:string, :null],
          description: "A MAC address in any common notation."
        },
        mtu: nullable(positive_int32),
        speed_mbps: nullable(positive_int32),
        metadata: nullable(free_object()),
        addresses: %{
          type: [:array, :null],
          items: %{anyOf: [%{type: :string, description: "An IP address or CIDR."}, address()]}
        },
        routing_domain: routing_domain(),
        vlan_mode: %{type: :string, enum: contract.interface_vlan_modes},
        vlans: %{
          type: :array,
          items: vlan_membership(contract),
          description:
            "VLAN memberships. At most one may be untagged, `access` mode allows at most " <>
              "one VLAN, and each source-local VLAN may appear once."
        },
        neighbors: %{
          type: :array,
          items: neighbor(contract),
          description: "LLDP or CDP neighbors. Each remote endpoint may appear once."
        },
        relationships: %{
          type: :array,
          items: relationship(contract),
          description: "Links to other interfaces on this host, never to itself."
        }
      },
      required: [:name]
    }
  end

  defp address do
    %{
      type: :object,
      properties: %{
        address: %{type: :string, description: "An IP address or CIDR."},
        kind: %{type: :string, enum: contract().address_kinds},
        scope: nullable(string()),
        metadata: nullable(free_object())
      },
      required: [:address]
    }
  end

  defp routing_domain do
    %{
      type: [:object, :null],
      description:
        "The source-local routing domain (VRF) this interface belongs to. Null withdraws " <>
          "an earlier claim; omitting it says nothing.",
      properties: %{
        key: code_point_bounded_string(),
        route_distinguisher: %{type: [:string, :null], description: "At most 255 bytes."},
        metadata: nullable(free_object())
      },
      required: [:key]
    }
  end

  defp vlan_membership(contract) do
    %{
      type: :object,
      properties: %{
        vid: %{type: :integer, minimum: 1, maximum: 4094},
        key: %{
          type: :string,
          minLength: 1,
          description:
            "Source-local VLAN identity, at most #{contract.max_source_local_vlan_key_bytes} " <>
              "bytes and not blank. Defaults to the scope and VID."
        },
        scope: code_point_bounded_string(),
        tagging_mode: %{type: :string, enum: contract.vlan_tagging_modes},
        metadata: free_object()
      },
      required: [:vid, :tagging_mode]
    }
  end

  defp neighbor(contract) do
    %{
      type: :object,
      properties: %{
        protocol: %{type: :string, enum: contract.neighbor_protocols},
        remote_chassis_id:
          code_point_bounded_string("Must be a MAC or network address when its kind says so."),
        remote_chassis_id_kind: %{type: :string, enum: contract.neighbor_chassis_id_kinds},
        remote_system_name: code_point_bounded_string(),
        remote_port_id: code_point_bounded_string("Must be a MAC address when its kind says so."),
        remote_port_id_kind: %{type: :string, enum: contract.neighbor_port_id_kinds},
        remote_port_description: code_point_bounded_string(),
        ttl_seconds: %{type: :integer, minimum: 1, maximum: 65_535},
        metadata: free_object()
      },
      required: [:protocol, :remote_chassis_id, :remote_port_id, :ttl_seconds]
    }
  end

  defp relationship(contract) do
    %{
      type: :object,
      properties: %{
        target: non_blank_string("The name of the related interface."),
        kind: %{type: :string, enum: contract.interface_relationship_kinds},
        metadata: free_object()
      },
      required: [:target, :kind]
    }
  end
end
