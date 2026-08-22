if Mix.env() == :dev do
  alias Renga.Accounts
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.User
  alias Renga.Inventory
  alias Renga.Inventory.IntakeApiKey
  alias Renga.Inventory.Resource
  alias Renga.Inventory.Source
  alias Renga.Repo

  email = "demo@renga.local"
  password = "renga-demo-password"
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

      connected_source =
        ensure_source.("host_agent", "orb-edge-collector", %{
          "site" => "ashburn",
          "environment" => "demo"
        })

      _poller_source =
        ensure_source.("switch_poller", "core-network-poller", %{"site" => "ashburn"})

      {:ok, {_agent, _lease}} = Inventory.record_agent_check_in(scope, connected_source.id)

      token_hash = :crypto.hash(:sha256, intake_token)

      case Repo.get_by(IntakeApiKey,
             organization_id: organization.id,
             name: "Orb demo collectors"
           ) do
        nil ->
          %IntakeApiKey{organization_id: organization.id}
          |> IntakeApiKey.create_changeset(%{name: "Orb demo collectors"}, token_hash)
          |> Repo.insert!()

        key ->
          key
          |> Ecto.Changeset.change(status: "active", token_hash: token_hash)
          |> Repo.update!()
      end

      seed_server = fn attrs ->
        resource =
          Repo.get_by(Resource,
            organization_id: organization.id,
            kind: "server",
            name: attrs.name
          )

        if resource do
          resource
        else
          {:ok, resource} =
            Inventory.create_resource(scope, %{
              kind: "server",
              name: attrs.name,
              display_name: attrs.display_name,
              lifecycle_state: attrs.lifecycle_state,
              labels: %{"site" => attrs.site, "service" => attrs.service},
              spec: %{"power" => attrs.power}
            })

          {:ok, _host} =
            Inventory.create_host(scope, resource.id, %{
              hostname: attrs.name,
              fqdn: "#{attrs.name}.demo.renga.local",
              vendor: attrs.vendor,
              model: attrs.model,
              asset_tag: attrs.asset_tag
            })

          {:ok, identifier} =
            Inventory.create_resource_identifier(scope, resource.id, %{
              kind: "serial_number",
              value: attrs.serial
            })

          {:ok, interface} =
            Inventory.create_interface(scope, resource.id, %{
              name: "eth0",
              mac_address: attrs.mac,
              status: attrs.interface_status,
              speed_mbps: 10_000
            })

          {:ok, _address} =
            Inventory.create_address(scope, interface.id, %{
              kind: "ipv4",
              address: attrs.address,
              scope: "global"
            })

          observed_at = DateTime.add(now, -attrs.observed_minutes, :minute)

          {:ok, observation} =
            Inventory.create_observation(scope, connected_source.id, %{
              observation_id: "orb-seed-#{attrs.name}",
              observed_at: observed_at,
              payload: %{"hostname" => attrs.name, "serial_number" => attrs.serial}
            })

          {:ok, _claim} =
            Inventory.create_resource_identifier_claim(
              scope,
              connected_source.id,
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
              source_id: connected_source.id,
              observation_id: observation.id,
              occurred_at: observed_at
            })

          resource
        end
      end

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
