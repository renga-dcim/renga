defmodule Renga.Accounts.OIDCDestinationsTest do
  # Changes the operator's allowlist.
  use Renga.DataCase, async: false

  import Renga.AccountsFixtures

  alias Renga.Accounts.OIDC
  alias Renga.Accounts.OIDC.Destinations
  alias Renga.FakeOIDCProvider
  alias Renga.FakeResolver

  setup do
    on_exit(fn -> Application.delete_env(:renga, :organization_provider_allow) end)
  end

  defp parse(address) do
    {:ok, parsed} = :inet.parse_strict_address(String.to_charlist(address))
    parsed
  end

  describe "public?/1" do
    test "refuses every non-public range" do
      for address <- ~w(
            0.0.0.0 10.1.2.3 100.64.0.1 127.0.0.1 169.254.169.254 172.16.0.1 172.31.255.255
            192.0.0.1 192.0.2.1 192.168.1.1 198.18.0.1 198.51.100.1 203.0.113.1 224.0.0.1
            240.0.0.1 255.255.255.255
            :: ::1 fe80::1 fc00::1 fd00:ec2::254 ff02::1 64:ff9b::a00:1 ::ffff:127.0.0.1
            ::ffff:10.0.0.1 2001:db8::1 2002:a00:1:: 2001::1 100::1
          ) do
        refute Destinations.public?(parse(address)), "#{address} counted as public"
      end
    end

    test "allows public unicast" do
      for address <- ~w(93.184.215.14 8.8.8.8 172.32.0.1 2606:4700::1111 ::ffff:8.8.8.8) do
        assert Destinations.public?(parse(address)), "#{address} counted as not public"
      end
    end
  end

  describe "check/1" do
    test "returns the public address to connect to" do
      FakeResolver.put("idp.example.com", [{8, 8, 8, 8}])
      assert {:ok, {8, 8, 8, 8}} = Destinations.check("https://idp.example.com/token")
    end

    test "refuses plain HTTP, private literals, and names that resolve privately" do
      FakeResolver.put("internal.example.com", [{10, 0, 0, 5}])
      FakeResolver.put("nowhere.example.com", [])

      for url <- [
            "http://idp.example.com/token",
            "https://127.0.0.1/token",
            "https://[::1]/token",
            "https://169.254.169.254/latest/meta-data",
            "https://internal.example.com/token",
            "https://nowhere.example.com/token"
          ] do
        assert {:error, :destination_not_allowed} = Destinations.check(url), url
      end
    end

    test "refuses a name when any of its addresses is private" do
      FakeResolver.put("mixed.example.com", [{8, 8, 8, 8}, {192, 168, 0, 10}])
      assert {:error, :destination_not_allowed} = Destinations.check("https://mixed.example.com/")
    end

    test "allows what the operator allows, and nothing else" do
      Application.put_env(
        :renga,
        :organization_provider_allow,
        Destinations.parse_allowlist("idp.corp.internal, 10.20.0.0/16, fd00::7")
      )

      FakeResolver.put("idp.corp.internal", [{10, 99, 0, 1}])
      FakeResolver.put("other.corp.internal", [{10, 20, 3, 4}])
      FakeResolver.put("outside.corp.internal", [{10, 21, 0, 1}])

      assert {:ok, {10, 99, 0, 1}} = Destinations.check("https://IDP.corp.internal/")
      assert {:ok, {10, 20, 3, 4}} = Destinations.check("https://other.corp.internal/")
      assert {:ok, _} = Destinations.check("https://[fd00::7]/")

      assert {:error, :destination_not_allowed} =
               Destinations.check("https://outside.corp.internal/")

      assert {:error, :destination_not_allowed} = Destinations.check("https://127.0.0.1/")
    end
  end

  describe "parse_allowlist/1" do
    test "reads hosts, ranges, and single addresses" do
      assert [{:host, "idp.example.com"}, {:range, {10, 0, 0, 0}, 8}, {:range, {10, 1, 1, 1}, 32}] =
               Destinations.parse_allowlist("IdP.example.com,10.0.0.0/8, 10.1.1.1,")
    end

    test "refuses what it cannot read" do
      for value <- ["10.0.0.0/33", "10.0.0.0/x", "not a host", "fd00::/129"] do
        assert_raise ArgumentError, fn -> Destinations.parse_allowlist(value) end
      end
    end
  end

  describe "organization providers" do
    setup do
      fake = FakeOIDCProvider.new()
      FakeOIDCProvider.stub(fake, observer: self())
      organization = Renga.InventoryFixtures.organization_fixture()

      provider =
        fake
        |> identity_provider_fixture()
        |> Ecto.Changeset.change(organization_id: organization.id)
        |> Renga.Repo.update!()

      %{fake: fake, provider: provider}
    end

    test "connect to the checked address with the provider's name", %{
      fake: fake,
      provider: provider
    } do
      host = URI.parse(fake.issuer).host
      FakeResolver.put(host, [{8, 8, 4, 4}])

      assert {:ok, _url, _attempt} = OIDC.start(provider, "http://localhost/cb")
      assert_received {FakeOIDCProvider, :request, "8.8.4.4", [^host]}
    end

    test "never reach a private address", %{fake: fake, provider: provider} do
      FakeResolver.put(URI.parse(fake.issuer).host, [{169, 254, 169, 254}])

      assert {:error, :provider_unavailable} = OIDC.start(provider, "http://localhost/cb")
      refute_received {FakeOIDCProvider, :request, _host, _header}
    end

    test "check the address again for every request", %{fake: fake, provider: provider} do
      host = URI.parse(fake.issuer).host
      {:ok, url, attempt} = OIDC.start(provider, "http://localhost/cb")
      params = FakeOIDCProvider.authorize(fake, url, %{"sub" => "subject-1"})

      # The name now points inside the deployment's network.
      FakeResolver.put(host, [{10, 0, 0, 1}])

      assert {:error, _reason} = OIDC.finish(attempt, params, "http://localhost/cb")
      refute_received {FakeOIDCProvider, :token_requested}
    end

    test "deployment providers keep the operator's trust", %{fake: fake} do
      deployment = identity_provider_fixture(fake)
      FakeResolver.put(URI.parse(fake.issuer).host, [{10, 0, 0, 1}])

      assert {:ok, _url, _attempt} = OIDC.start(deployment, "http://localhost/cb")
    end
  end
end
