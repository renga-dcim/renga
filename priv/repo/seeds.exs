if Mix.env() == :dev do
  alias Renga.Accounts
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.User
  alias Renga.Catalog
  alias Renga.Catalog.HardwareType
  alias Renga.Catalog.InventoryItem
  alias Renga.Catalog.Manufacturer
  alias Renga.Catalog.ModuleBay
  alias Renga.Catalog.ModuleType
  alias Renga.DCIM
  alias Renga.DCIM.Location
  alias Renga.DCIM.Rack
  alias Renga.DCIM.SiteGroup
  alias Renga.Inventory
  alias Renga.Inventory.Address
  alias Renga.Inventory.Agent
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Host
  alias Renga.Inventory.IntakeApiKey
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.ResourceIdentifierClaim
  alias Renga.Inventory.Source
  alias Renga.Repo

  email = "demo@renga.local"
  password = "supersecure!"
  now = Renga.Time.utc_now_ms()
  agent_directory = Path.expand("../../dev/renga-agent", __DIR__)
  intake_token_path = Path.join(agent_directory, "intake-key")

  File.mkdir_p!(agent_directory)

  intake_token =
    case File.read(intake_token_path) do
      {:ok, token} ->
        String.trim(token)

      {:error, :enoent} ->
        token =
          "renga_intake_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        File.write!(intake_token_path, token <> "\n")
        token
    end

  File.chmod!(intake_token_path, 0o600)

  {:ok, _seeded} =
    Repo.transaction(fn ->
      user =
        case Accounts.get_user_by_email(email) do
          nil -> %User{} |> User.email_changeset(%{email: email})
          user -> Ecto.Changeset.change(user)
        end
        |> User.password_changeset(%{password: password})
        |> Ecto.Changeset.put_change(:confirmed_at, now)
        |> Repo.insert_or_update!()

      organization =
        Accounts.get_organization_by_slug("renga-labs") ||
          case Accounts.create_organization(%{
                 name: "Renga Labs",
                 slug: "renga-labs",
                 settings: %{"environment" => "orb-demo"}
               }) do
            {:ok, organization} -> organization
            {:error, changeset} -> raise inspect(changeset.errors)
          end

      case Repo.get_by(OrganizationMembership,
             organization_id: organization.id,
             user_id: user.id
           ) do
        nil ->
          {:ok, _membership} =
            Accounts.create_organization_membership(organization, %{
              user_id: user.id,
              role: "owner"
            })

        membership ->
          membership
          |> OrganizationMembership.changeset(%{role: "owner", status: "active"})
          |> Repo.update!()
      end

      scope = Accounts.scope_for_user(user, organization.id)

      ensure_source = fn kind, name, metadata ->
        Repo.get_by(Source, organization_id: organization.id, name: name) ||
          case Inventory.create_source(scope, %{kind: kind, name: name, metadata: metadata}) do
            {:ok, source} -> source
            {:error, changeset} -> raise inspect(changeset.errors)
          end
      end

      demo_source =
        Repo.get_by(Source, organization_id: organization.id, name: "orb-edge-collector") ||
          Repo.get_by(Source, organization_id: organization.id, name: "seeded-demo-inventory") ||
          ensure_source.("manual", "seeded-demo-inventory", %{})

      # Preserve the source ID so existing demo observations and claims retain their provenance.
      demo_source =
        demo_source
        |> Source.changeset(%{
          kind: "manual",
          name: "seeded-demo-inventory",
          metadata: %{
            "description" => "Synthetic inventory created by the development seed",
            "environment" => "demo"
          }
        })
        |> Repo.update!()

      if agent = Repo.get_by(Agent, organization_id: organization.id, source_id: demo_source.id) do
        Repo.delete!(agent)
      end

      if poller =
           Repo.get_by(Source, organization_id: organization.id, name: "core-network-poller") do
        Repo.delete!(poller)
      end

      token_hash = :crypto.hash(:sha256, intake_token)

      intake_key =
        Repo.get_by(IntakeApiKey,
          organization_id: organization.id,
          name: "Local orb agent"
        ) ||
          Repo.get_by(IntakeApiKey,
            organization_id: organization.id,
            name: "Orb demo collectors"
          )

      case intake_key do
        nil ->
          %IntakeApiKey{organization_id: organization.id}
          |> IntakeApiKey.create_changeset(%{name: "Local orb agent"}, token_hash)
          |> Repo.insert!()

        key ->
          key
          |> Ecto.Changeset.change(
            name: "Local orb agent",
            status: "active",
            token_hash: token_hash
          )
          |> Repo.update!()
      end

      seed_server = fn attrs ->
        resource_attrs = %{
          kind: "server",
          name: attrs.name,
          display_name: attrs.display_name,
          lifecycle_state: attrs.lifecycle_state,
          labels: %{"site" => attrs.site, "service" => attrs.service},
          spec: %{"power" => attrs.power}
        }

        resource =
          case Repo.get_by(Resource,
                 organization_id: organization.id,
                 kind: "server",
                 name: attrs.name
               ) do
            nil ->
              {:ok, resource} = Inventory.create_resource(scope, resource_attrs)
              resource

            resource ->
              if Map.take(resource, Map.keys(resource_attrs)) == resource_attrs do
                resource
              else
                {:ok, resource} = Inventory.update_resource(scope, resource, resource_attrs)
                resource
              end
          end

        host_attrs = %{
          hostname: attrs.name,
          fqdn: "#{attrs.name}.demo.renga.local",
          vendor: attrs.vendor,
          model: attrs.model,
          asset_tag: attrs.asset_tag
        }

        case Repo.get_by(Host, organization_id: organization.id, resource_id: resource.id) do
          nil ->
            {:ok, _host} = Inventory.create_host(scope, resource.id, host_attrs)

          host ->
            host |> Host.changeset(host_attrs) |> Repo.update!()
        end

        identifier_attrs = %{kind: "serial_number", value: attrs.serial}

        identifier =
          case Repo.get_by(ResourceIdentifier,
                 organization_id: organization.id,
                 resource_id: resource.id,
                 kind: "serial_number"
               ) do
            nil ->
              {:ok, identifier} =
                Inventory.create_resource_identifier(scope, resource.id, identifier_attrs)

              identifier

            identifier ->
              identifier |> ResourceIdentifier.changeset(identifier_attrs) |> Repo.update!()
          end

        interface_attrs = %{
          name: "eth0",
          mac_address: attrs.mac,
          status: attrs.interface_status,
          speed_mbps: 10_000
        }

        interface =
          case Repo.get_by(Interface,
                 organization_id: organization.id,
                 resource_id: resource.id,
                 name: "eth0"
               ) do
            nil ->
              {:ok, interface} =
                Inventory.create_interface(scope, resource.id, interface_attrs)

              interface

            interface ->
              interface |> Interface.changeset(interface_attrs) |> Repo.update!()
          end

        address_attrs = %{kind: "ipv4", address: attrs.address, scope: "global"}

        case Repo.get_by(Address,
               organization_id: organization.id,
               interface_id: interface.id
             ) do
          nil ->
            {:ok, _address} = Inventory.create_address(scope, interface.id, address_attrs)

          address ->
            address |> Address.changeset(address_attrs) |> Repo.update!()
        end

        observation_id = "orb-seed-#{attrs.name}"

        if observation =
             Repo.get_by(Observation,
               organization_id: organization.id,
               source_id: demo_source.id,
               idempotency_key: observation_id
             ) do
          if event =
               Repo.get_by(ChangeEvent,
                 organization_id: organization.id,
                 observation_id: observation.id
               ) do
            Repo.delete!(event)
          end

          if claim =
               Repo.get_by(ResourceIdentifierClaim,
                 organization_id: organization.id,
                 observation_id: observation.id
               ) do
            Repo.delete!(claim)
          end

          Repo.delete!(observation)
        end

        observed_at = DateTime.add(now, -attrs.observed_minutes, :minute)

        {:ok, observation} =
          Inventory.create_observation(scope, demo_source.id, %{
            observation_id: observation_id,
            observed_at: observed_at,
            payload: %{"hostname" => attrs.name, "serial_number" => attrs.serial}
          })

        {:ok, _claim} =
          Inventory.create_resource_identifier_claim(
            scope,
            demo_source.id,
            observation.id,
            %{
              resource_id: resource.id,
              resource_identifier_id: identifier.id,
              kind: "serial_number",
              value: attrs.serial,
              confidence: 100
            }
          )

        {:ok, _condition} =
          Inventory.put_resource_condition(scope, resource.id, %{
            type: "InventoryCurrent",
            status: attrs.inventory_status,
            reason: attrs.inventory_reason,
            message: attrs.inventory_message
          })

        {:ok, _event} =
          Inventory.create_change_event(scope, %{
            kind: "discovered",
            resource_id: resource.id,
            source_id: demo_source.id,
            observation_id: observation.id,
            occurred_at: observed_at
          })

        resource
      end

      compute =
        seed_server.(%{
          name: "compute-01",
          display_name: "Primary compute node",
          lifecycle_state: "active",
          site: "ashburn",
          service: "compute",
          power: "on",
          vendor: "Dell",
          model: "PowerEdge R760",
          asset_tag: "DC1-COMPUTE-001",
          serial: "DEMO-COMP-001",
          mac: "02:00:00:00:10:01",
          interface_status: "up",
          address: "192.0.2.11/24",
          observed_minutes: 2,
          inventory_status: "true",
          inventory_reason: "ObservationReceived",
          inventory_message: "Inventory is current."
        })

      database =
        seed_server.(%{
          name: "database-01",
          display_name: "PostgreSQL primary",
          lifecycle_state: "active",
          site: "ashburn",
          service: "database",
          power: "on",
          vendor: "HPE",
          model: "ProLiant DL380 Gen11",
          asset_tag: "DC1-DATA-001",
          serial: "DEMO-DATA-001",
          mac: "02:00:00:00:20:01",
          interface_status: "up",
          address: "192.0.2.21/24",
          observed_minutes: 8,
          inventory_status: "true",
          inventory_reason: "ObservationReceived",
          inventory_message: "Inventory is current."
        })

      edge =
        seed_server.(%{
          name: "edge-legacy-01",
          display_name: "Legacy edge node",
          lifecycle_state: "inactive",
          site: "chicago",
          service: "edge",
          power: "off",
          vendor: "Supermicro",
          model: "SYS-510T-MR",
          asset_tag: "CHI-EDGE-009",
          serial: "DEMO-EDGE-009",
          mac: "02:00:00:00:30:09",
          interface_status: "down",
          address: "198.51.100.19/24",
          observed_minutes: 180,
          inventory_status: "false",
          inventory_reason: "ObservationExpired",
          inventory_message: "No recent inventory observation."
        })

      find_projection = fn schema, kind, name ->
        case Repo.get_by(Resource,
               organization_id: organization.id,
               kind: kind,
               name: name
             ) do
          nil ->
            nil

          resource ->
            Repo.get_by(schema, organization_id: organization.id, resource_id: resource.id)
        end
      end

      dell =
        find_projection.(Manufacturer, "manufacturer", "Dell Technologies") ||
          case Catalog.create_manufacturer(
                 scope,
                 %{name: "Dell Technologies", lifecycle_state: "active"},
                 %{
                   slug: "dell-technologies",
                   description: "Seeded manufacturer for the orb hardware catalog"
                 }
               ) do
            {:ok, manufacturer} -> manufacturer
            {:error, reason} -> raise inspect(reason)
          end

      poweredge =
        Repo.get_by(HardwareType,
          organization_id: organization.id,
          manufacturer_id: dell.id,
          model: "PowerEdge R760"
        )
        |> case do
          nil ->
            case Catalog.create_hardware_type(
                   scope,
                   %{lifecycle_state: "active"},
                   %{
                     manufacturer_id: dell.id,
                     model: "PowerEdge R760",
                     device_class: "server",
                     description: "Two-socket 2U compute platform"
                   }
                 ) do
              {:ok, hardware_type} -> hardware_type
              {:error, reason} -> raise inspect(reason)
            end

          hardware_type ->
            Repo.preload(hardware_type, :resource)
        end

      poweredge =
        if poweredge.resource.name == "Dell Technologies PowerEdge R760" do
          poweredge
        else
          {:ok, resource} =
            Inventory.update_resource(scope, poweredge.resource, %{
              name: "Dell Technologies PowerEdge R760",
              display_name: "Dell Technologies PowerEdge R760"
            })

          %{poweredge | resource: resource}
        end

      if Catalog.get_hardware_type!(scope, poweredge.id).revisions == [] do
        {:ok, _revision} =
          Catalog.create_hardware_type_revision(
            scope,
            poweredge,
            %{
              part_number: "R760-DEMO",
              height_units: 2,
              width_mm: "482.0",
              depth_mm: "772.0",
              weight_kg: "28.6",
              airflow: "front_to_rear",
              specifications: %{"cpu_sockets" => 2, "memory_slots" => 32}
            },
            [
              %{kind: "cpu", name: "CPU 1", position: "CPU1"},
              %{kind: "cpu", name: "CPU 2", position: "CPU2"},
              %{kind: "memory", name: "DIMM A1", position: "A1"},
              %{kind: "disk", name: "Boot disk 1", position: "Bay 1"},
              %{
                kind: "interface",
                name: "Management interface",
                position: "eth0",
                attributes: %{"mac_address" => "02:00:00:00:10:01"}
              },
              %{kind: "module_bay", name: "BOSS slot", position: "internal"}
            ]
          )
      end

      {:ok, _assignment} = Catalog.assign_hardware_type(scope, compute.id, poweredge.id)

      boss_type =
        Repo.get_by(ModuleType,
          organization_id: organization.id,
          manufacturer_id: dell.id,
          model: "BOSS-N1"
        )
        |> case do
          nil ->
            case Catalog.create_module_type(
                   scope,
                   %{lifecycle_state: "active"},
                   %{
                     manufacturer_id: dell.id,
                     model: "BOSS-N1",
                     module_class: "other",
                     description: "Internal boot optimized storage module"
                   }
                 ) do
              {:ok, module_type} -> module_type
              {:error, reason} -> raise inspect(reason)
            end

          module_type ->
            Repo.preload(module_type, :resource)
        end

      boss_type =
        if boss_type.resource.name == "Dell Technologies BOSS-N1" do
          boss_type
        else
          {:ok, resource} =
            Inventory.update_resource(scope, boss_type.resource, %{
              name: "Dell Technologies BOSS-N1",
              display_name: "Dell Technologies BOSS-N1"
            })

          %{boss_type | resource: resource}
        end

      if Catalog.get_module_type!(scope, boss_type.id).revisions == [] do
        {:ok, _revision} =
          Catalog.create_module_type_revision(scope, boss_type, %{part_number: "BOSS-N1-DEMO"})
      end

      boss_module =
        Enum.find(Catalog.list_modules(scope), &(&1.resource.name == "compute-01 BOSS module")) ||
          case Catalog.create_module(
                 scope,
                 boss_type,
                 %{name: "compute-01 BOSS module", lifecycle_state: "active"},
                 %{status: "active", serial_number: "DEMO-BOSS-001"}
               ) do
            {:ok, module} -> module
            {:error, reason} -> raise inspect(reason)
          end

      boss_bay =
        Repo.get_by(ModuleBay,
          organization_id: organization.id,
          owner_resource_id: compute.id,
          name: "boss-slot"
        ) ||
          case Catalog.create_module_bay(
                 scope,
                 compute.id,
                 %{name: "boss-slot", label: "BOSS slot", position: "internal"},
                 [boss_type.id]
               ) do
            {:ok, bay} -> bay
            {:error, reason} -> raise inspect(reason)
          end

      if is_nil(Catalog.get_desired_module_assignment(scope, boss_bay.id)) do
        {:ok, _desired} =
          Catalog.put_desired_module_assignment(scope, boss_bay.id, boss_type.id)
      end

      if is_nil(Catalog.get_current_module_installation(scope, boss_bay.id)) do
        {:ok, _installation} = Catalog.install_module(scope, boss_bay.id, boss_module.id)
      end

      Repo.get_by(InventoryItem,
        organization_id: organization.id,
        owner_resource_id: compute.id,
        name: "Cooling fan 1"
      ) ||
        case Catalog.create_inventory_item(scope, compute.id, %{
               name: "Cooling fan 1",
               kind: "fan",
               status: "installed",
               position: "fan-1",
               part_number: "R760-FAN-DEMO"
             }) do
          {:ok, item} -> item
          {:error, reason} -> raise inspect(reason)
        end

      site_group =
        find_projection.(SiteGroup, "site_group", "North America") ||
          case DCIM.create_site_group(
                 scope,
                 %{name: "North America", lifecycle_state: "active"},
                 %{description: "Seeded regional grouping for orb demo facilities"}
               ) do
            {:ok, site_group} -> site_group
            {:error, reason} -> raise inspect(reason)
          end

      ensure_site = fn name, slug, attrs ->
        Repo.get_by(Renga.DCIM.Site, organization_id: organization.id, slug: slug) ||
          case DCIM.create_site(
                 scope,
                 %{name: name, lifecycle_state: "active"},
                 Map.merge(
                   %{
                     site_group_id: site_group.id,
                     slug: slug,
                     status: "active",
                     time_zone: "Etc/UTC"
                   },
                   attrs
                 )
               ) do
            {:ok, site} -> site
            {:error, reason} -> raise inspect(reason)
          end
      end

      ashburn =
        ensure_site.("Ashburn DC1", "ashburn-dc1", %{
          physical_address: "21700 Atlantic Boulevard, Sterling, VA",
          description: "Primary seeded data center"
        })

      chicago =
        ensure_site.("Chicago Edge", "chicago-edge", %{
          physical_address: "350 East Cermak Road, Chicago, IL",
          description: "Seeded edge facility"
        })

      ensure_location = fn site, name, kind ->
        find_projection.(Location, "location", name) ||
          case DCIM.create_location(
                 scope,
                 %{name: name, lifecycle_state: "active"},
                 %{site_id: site.id, kind: kind, status: "active"}
               ) do
            {:ok, location} -> location
            {:error, reason} -> raise inspect(reason)
          end
      end

      ashburn_hall = ensure_location.(ashburn, "Ashburn Data Hall A", "data_hall")
      chicago_room = ensure_location.(chicago, "Chicago Edge Room", "room")

      ensure_rack = fn site, location, name, facility_id ->
        find_projection.(Rack, "rack", name) ||
          case DCIM.create_rack(
                 scope,
                 %{name: name, lifecycle_state: "active"},
                 %{
                   site_id: site.id,
                   location_id: location.id,
                   status: "active",
                   facility_id: facility_id,
                   height_units: 42,
                   width: "19_inch",
                   starting_unit: "bottom",
                   outer_width: "600",
                   outer_depth: "1200",
                   dimension_unit: "mm"
                 }
               ) do
            {:ok, rack} -> rack
            {:error, reason} -> raise inspect(reason)
          end
      end

      ashburn_rack_a01 = ensure_rack.(ashburn, ashburn_hall, "ASH-A01", "A01")
      ashburn_rack_a02 = ensure_rack.(ashburn, ashburn_hall, "ASH-A02", "A02")
      chicago_rack = ensure_rack.(chicago, chicago_room, "CHI-E01", "E01")

      place_resource = fn resource, rack, position, height_units ->
        placement = %{
          rack_id: rack.id,
          position: position,
          height_units: height_units,
          face: "front"
        }

        case DCIM.put_desired_placement(scope, resource.id, placement) do
          {:ok, _placement} -> :ok
          {:error, reason} -> raise inspect(reason)
        end

        case DCIM.put_current_placement(scope, resource.id, Map.put(placement, :confirmed, true)) do
          {:ok, _placement} -> :ok
          {:error, reason} -> raise inspect(reason)
        end
      end

      place_resource.(compute, ashburn_rack_a01, 20, 2)
      place_resource.(database, ashburn_rack_a02, 16, 2)
      place_resource.(edge, chicago_rack, 10, 1)

      %{user: user, organization: organization}
    end)

  agent_config_path = Path.join(agent_directory, "agent.toml")

  File.write!(agent_config_path, """
  renga_url = "http://127.0.0.1:4000"
  allow_insecure_http = true
  intake_api_key = "#{intake_token}"
  inventory_interval_seconds = 60
  checkin_interval_seconds = 10
  config_refresh_interval_seconds = 60
  request_timeout_seconds = 5
  max_retry_attempts = 3
  """)

  File.chmod!(agent_config_path, 0o600)

  IO.puts("""

  Seeded Renga orb demo data.
    Login:    #{email}
    Password: #{password}
    Agent:    configured in dev/renga-agent
  """)
end
