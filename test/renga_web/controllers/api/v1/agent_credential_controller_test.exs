defmodule RengaWeb.Api.V1.AgentCredentialControllerTest do
  use RengaWeb.ConnCase, async: false

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Enrollment
  alias Renga.Enrollment.{AgentCredential, CredentialEvent, EnrollmentReplay}
  alias Renga.Inventory
  alias Renga.Inventory.{Agent, AgentLease, Observation}
  alias Renga.Repo
  alias RengaWeb.AgentCredentialAuth

  @installation_id "67e55044-10b1-426f-9247-bb680e5fe0c8"
  @other_installation_id "8ea9ae04-bf9b-4c34-8192-4f617eade95e"

  setup do
    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Key auth organization",
        slug: "key-auth-#{System.unique_integer([:positive])}"
      })

    user = user_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "admin"})

    scope =
      Accounts.scope_for(organization, %{user: user, membership_id: membership.id})

    {:ok, {source, token}} =
      Inventory.create_source_with_token(scope, %{kind: "host_agent", name: "key-agent"})

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("x-renga-installation-id", @installation_id)
      |> post("/api/v1/agent/checkins", %{})

    assert %{"agent" => %{"id" => agent_id}} = json_response(conn, 202)
    agent = Repo.get!(Agent, agent_id)
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    credential =
      %AgentCredential{
        organization_id: organization.id,
        source_id: source.id,
        agent_id: agent.id,
        credential_id: :crypto.strong_rand_bytes(32),
        public_key: public_key,
        key_thumbprint: :crypto.hash(:sha256, public_key)
      }
      |> AgentCredential.changeset(%{
        expires_at: DateTime.add(Renga.Time.utc_now_ms(), 3_600, :second)
      })
      |> Repo.insert!()

    %{
      organization: organization,
      scope: scope,
      source: source,
      agent: agent,
      credential: credential,
      private_key: private_key
    }
  end

  test "valid signed check-in and observation traverse the endpoint and persist", fixture do
    agent_count = Repo.aggregate(Agent, :count)
    check_in = signed_post(fixture, "/api/v1/key/agent/checkins", Jason.encode!(%{}))
    assert %{"status" => "accepted"} = json_response(check_in, 202)

    body = Jason.encode!(observation_payload(fixture.source))
    observation = signed_post(fixture, "/api/v1/key/observations", body)
    assert %{"status" => "accepted", "duplicate" => false} = json_response(observation, 202)
    assert Repo.aggregate(Observation, :count) == 1
    assert Repo.aggregate(Agent, :count) == agent_count
  end

  test "signature binds exact body, query string, and normalized content type", fixture do
    body = Jason.encode!(%{})

    for tamper <- [:body, :query, :content_type] do
      nonce = nonce()
      timestamp = now()
      target = "/api/v1/key/agent/checkins?mode=one"
      headers = signed_headers(fixture, target, body, timestamp, nonce, "application/json")

      {request_target, request_body, request_type} =
        case tamper do
          :body -> {target, body <> " ", "application/json"}
          :query -> {"/api/v1/key/agent/checkins?mode=two", body, "application/json"}
          :content_type -> {target, body, "application/problem+json"}
        end

      conn = raw_post(request_target, request_body, replace_content_type(headers, request_type))
      assert unauthorized?(conn), "expected #{tamper} tampering to fail"
    end
  end

  test "rejects duplicate and malformed authentication headers", fixture do
    valid = signed_headers(fixture, "/api/v1/key/agent/checkins", "{}", now(), nonce())

    duplicate =
      valid
      |> Kernel.++([{"authorization", "RengaKey duplicate"}])
      |> then(&raw_post("/api/v1/key/agent/checkins", "{}", &1))

    assert unauthorized?(duplicate)

    for {name, value} <- [
          {"authorization", "Bearer malformed"},
          {"x-renga-installation-id", "not-a-uuid"},
          {"x-renga-timestamp", "+1"},
          {"x-renga-nonce", "short"},
          {"x-renga-signature", "short"}
        ] do
      conn = raw_post("/api/v1/key/agent/checkins", "{}", replace_header(valid, name, value))
      assert unauthorized?(conn), "expected malformed #{name} to fail"
    end
  end

  test "rejects stale and future timestamps and replayed nonces", fixture do
    for timestamp <- [now() - 61, now() + 61] do
      conn = signed_post(fixture, "/api/v1/key/agent/checkins", "{}", timestamp: timestamp)
      assert unauthorized?(conn)
    end

    nonce = nonce()
    first = signed_post(fixture, "/api/v1/key/agent/checkins", "{}", nonce: nonce)
    assert json_response(first, 202)
    replay = signed_post(fixture, "/api/v1/key/agent/checkins", "{}", nonce: nonce)
    assert unauthorized?(replay)
    assert Repo.aggregate(EnrollmentReplay, :count) == 1
  end

  test "retains a future-timestamp nonce beyond its final accepted second", fixture do
    timestamp = now() + 60

    assert fixture
           |> signed_post("/api/v1/key/agent/checkins", "{}", timestamp: timestamp)
           |> response(202)

    replay = Repo.one!(EnrollmentReplay)

    assert DateTime.compare(replay.expires_at, DateTime.from_unix!(timestamp + 61, :second)) ==
             :eq
  end

  test "two concurrent requests with one runtime nonce accept exactly once", fixture do
    runtime_nonce = nonce()

    results =
      concurrently(2, fn ->
        fixture
        |> signed_post("/api/v1/key/agent/checkins", "{}", nonce: runtime_nonce)
        |> then(& &1.status)
      end)

    assert Enum.sort(results) == [202, 401]

    assert Repo.aggregate(
             from(r in EnrollmentReplay,
               where:
                 r.agent_credential_id == ^fixture.credential.id and
                   r.kind == "runtime_nonce"
             ),
             :count
           ) == 1
  end

  test "stale authenticated runtime structs cannot mutate inventory after lifecycle changes",
       fixture do
    lease_before = Repo.get_by!(AgentLease, agent_id: fixture.agent.id)

    assert {:ok, revoked} =
             Enrollment.revoke_agent_credential(fixture.scope, fixture.credential.id)

    assert revoked.status == "revoked"

    assert {:error, :agent_credential_changed} =
             Inventory.record_credential_agent_check_in(
               fixture.scope,
               fixture.source,
               fixture.agent,
               fixture.credential,
               %{}
             )

    lease_after = Repo.get_by!(AgentLease, agent_id: fixture.agent.id)
    assert lease_after.renewed_at == lease_before.renewed_at
    assert lease_after.expires_at == lease_before.expires_at

    other = second_fixture()

    assert {:ok, quarantined} =
             Enrollment.quarantine_agent_credential(other.scope, other.credential.id)

    assert quarantined.status == "quarantined"

    assert {:error, :agent_credential_changed} =
             Inventory.ingest_credential_observation(
               other.scope,
               other.source,
               other.agent,
               other.credential,
               %{
                 idempotency_key: "stale-key-observation",
                 observed_at: Renga.Time.utc_now_ms(),
                 payload: %{}
               }
             )

    refute Repo.get_by(Observation, idempotency_key: "stale-key-observation")
  end

  test "concurrent renewal and terminal lifecycle mutation serialize without a late renewal",
       fixture do
    for action <- [:revoke, :quarantine] do
      current = Repo.get!(AgentCredential, fixture.credential.id)

      results =
        concurrently([
          fn ->
            Enrollment.renew_agent_credential(
              fixture.scope,
              fixture.source,
              fixture.agent,
              fixture.credential
            )
          end,
          fn -> apply(Enrollment, action_agent_function(action), [fixture.scope, current.id]) end
        ])

      assert Enum.any?(results, &match?({:ok, %AgentCredential{}}, &1))

      stored = Repo.get!(AgentCredential, current.id)
      expected_status = if action == :revoke, do: "revoked", else: "quarantined"
      assert stored.status == expected_status

      events =
        Repo.all(
          from e in CredentialEvent,
            where: e.agent_credential_id == ^current.id,
            select: {e.kind, e.occurred_at}
        )

      {^expected_status, terminal_at} = Enum.find(events, &(elem(&1, 0) == expected_status))

      assert Enum.all?(events, fn
               {"renewed", renewed_at} -> DateTime.compare(renewed_at, terminal_at) in [:lt, :eq]
               _event -> true
             end)

      if action == :revoke do
        Repo.update_all(from(c in AgentCredential, where: c.id == ^current.id),
          set: [status: "active", revoked_at: nil, expires_at: fixture.credential.expires_at]
        )
      end
    end
  end

  test "rejects wrong installation, credential, key, and signature", fixture do
    valid = signed_headers(fixture, "/api/v1/key/agent/checkins", "{}", now(), nonce())

    wrongs = [
      replace_header(valid, "x-renga-installation-id", @other_installation_id),
      replace_header(
        valid,
        "authorization",
        "RengaKey #{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}"
      ),
      replace_header(
        valid,
        "x-renga-signature",
        Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false)
      )
    ]

    Enum.each(wrongs, fn headers ->
      assert raw_post("/api/v1/key/agent/checkins", "{}", headers) |> unauthorized?()
    end)

    {_, wrong_private_key} = :crypto.generate_key(:eddsa, :ed25519)

    assert fixture
           |> Map.put(:private_key, wrong_private_key)
           |> signed_post("/api/v1/key/agent/checkins", "{}")
           |> unauthorized?()
  end

  test "a credential from another organization cannot authenticate this installation", fixture do
    other = second_fixture()

    conn =
      signed_post(other, "/api/v1/key/agent/checkins", "{}", installation_id: @installation_id)

    assert unauthorized?(conn)
    assert Repo.get!(Agent, fixture.agent.id).source_id == fixture.source.id
  end

  test "inactive aggregate and credential states are rejected", fixture do
    mutations = [
      {fixture.organization, :status, "disabled"},
      {fixture.source, :status, "revoked"},
      {fixture.agent, :status, "disabled"},
      {fixture.credential, :status, "quarantined"},
      {fixture.credential, :expires_at, DateTime.add(Renga.Time.utc_now_ms(), -1, :second)}
    ]

    Enum.each(mutations, fn {row, field, value} ->
      Repo.update_all(from(r in row.__struct__, where: r.id == ^row.id), set: [{field, value}])
      assert fixture |> signed_post("/api/v1/key/agent/checkins", "{}") |> unauthorized?()

      Repo.update_all(from(r in row.__struct__, where: r.id == ^row.id),
        set: [{field, Map.fetch!(row, field)}]
      )
    end)

    for status <- ["revoked", "expired"] do
      past = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

      Repo.update_all(from(c in AgentCredential, where: c.id == ^fixture.credential.id),
        set: [status: status, expires_at: past, revoked_at: past]
      )

      assert fixture |> signed_post("/api/v1/key/agent/checkins", "{}") |> unauthorized?()

      Repo.update_all(from(c in AgentCredential, where: c.id == ^fixture.credential.id),
        set: [status: "active", expires_at: fixture.credential.expires_at, revoked_at: nil]
      )
    end
  end

  test "unsupported, multipart, missing content types and unread bodies cannot authenticate",
       fixture do
    for content_type <- ["text/plain", "multipart/form-data; boundary=x", nil] do
      headers = signed_headers(fixture, "/api/v1/key/agent/checkins", "{}", now(), nonce())

      headers =
        if content_type,
          do: replace_content_type(headers, content_type),
          else: Enum.reject(headers, &(elem(&1, 0) == "content-type"))

      body = if content_type == "multipart/form-data; boundary=x", do: "--x--\r\n", else: "{}"

      conn =
        if content_type,
          do: raw_post("/api/v1/key/agent/checkins", body, headers),
          else: endpoint_post_without_content_type("/api/v1/key/agent/checkins", body, headers)

      assert conn.status in [401, 406, 415]
    end

    # GET has no matching route and, importantly, cannot reuse a digest from a signed POST.
    conn = get(build_conn(), "/api/v1/key/agent/checkins")
    assert conn.status == 404
  end

  test "key routes never create or rebind agents", fixture do
    count = Repo.aggregate(Agent, :count)
    bad_body = Jason.encode!(%{"source" => %{"kind" => "host_agent", "source_id" => "other"}})
    assert fixture |> signed_post("/api/v1/key/agent/checkins", bad_body) |> json_response(422)
    assert Repo.aggregate(Agent, :count) == count
    assert Repo.get!(Agent, fixture.agent.id).installation_id == @installation_id
  end

  test "renewal stays inside the server horizon and appends immutable event history", fixture do
    issued_at = DateTime.add(Renga.Time.utc_now_ms(), -10, :second)
    issued = event!(fixture, "issued", issued_at)

    Repo.update_all(from(c in AgentCredential, where: c.id == ^fixture.credential.id),
      set: [expires_at: DateTime.add(Renga.Time.utc_now_ms(), 3_600, :second)]
    )

    conn = signed_post(fixture, "/api/v1/key/agent/credentials/renew", "{}")

    assert %{"credential_id" => credential_id, "expires_at" => expires_at} =
             json_response(conn, 200)

    assert credential_id == Base.url_encode64(fixture.credential.credential_id, padding: false)
    {:ok, expiry, 0} = DateTime.from_iso8601(expires_at)
    assert DateTime.diff(expiry, Renga.Time.utc_now_ms(), :second) in 86_398..86_400

    events = Repo.all(from e in CredentialEvent, order_by: e.inserted_at)
    assert Enum.map(events, & &1.kind) == ["issued", "renewed"]
    assert Repo.get!(CredentialEvent, issued.id).occurred_at == issued_at

    second = signed_post(fixture, "/api/v1/key/agent/credentials/renew", "{}")
    assert json_response(second, 200)["expires_at"] == expires_at
    assert Repo.aggregate(CredentialEvent, :count) == 2

    too_far = DateTime.add(Renga.Time.utc_now_ms(), 86_500, :second)

    Repo.update_all(from(c in AgentCredential, where: c.id == ^fixture.credential.id),
      set: [expires_at: too_far]
    )

    assert fixture
           |> signed_post("/api/v1/key/agent/credentials/renew", "{}")
           |> json_response(401)

    assert Repo.aggregate(CredentialEvent, :count) == 2
  end

  defp signed_post(fixture, target, body, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, now())
    nonce = Keyword.get(opts, :nonce, nonce())
    installation_id = Keyword.get(opts, :installation_id, @installation_id)

    headers =
      signed_headers(fixture, target, body, timestamp, nonce, "application/json", installation_id)

    raw_post(target, body, headers)
  end

  defp signed_headers(
         fixture,
         target,
         body,
         timestamp,
         nonce,
         content_type \\ "application/json",
         installation_id \\ @installation_id
       ) do
    encoded_id = Base.url_encode64(fixture.credential.credential_id, padding: false)
    encoded_nonce = Base.url_encode64(nonce, padding: false)

    values = %{
      credential_id_encoded: encoded_id,
      installation_id: installation_id,
      method: "POST",
      request_target: target,
      content_type: content_type,
      timestamp: timestamp,
      nonce_encoded: encoded_nonce,
      body_digest: :crypto.hash(:sha256, body)
    }

    signature =
      :crypto.sign(:eddsa, :none, AgentCredentialAuth.transcript(values), [
        fixture.private_key,
        :ed25519
      ])

    [
      {"authorization", "RengaKey #{encoded_id}"},
      {"x-renga-installation-id", installation_id},
      {"x-renga-timestamp", Integer.to_string(timestamp)},
      {"x-renga-nonce", encoded_nonce},
      {"x-renga-signature", Base.url_encode64(signature, padding: false)},
      {"content-type", content_type}
    ]
  end

  defp raw_post(target, body, headers) do
    conn =
      Enum.reduce(headers, build_conn(), fn {name, value}, conn ->
        Plug.Conn.prepend_req_headers(conn, [{name, value}])
      end)

    post(conn, target, body)
  end

  defp endpoint_post_without_content_type(target, body, headers) do
    conn =
      headers
      |> Enum.reduce(Plug.Test.conn(:post, target, body), fn {name, value}, conn ->
        Plug.Conn.prepend_req_headers(conn, [{name, value}])
      end)

    RengaWeb.Endpoint.call(conn, RengaWeb.Endpoint.init([]))
  end

  defp unauthorized?(conn),
    do: match?(%{"errors" => [%{"path" => "authorization"} | _]}, json_response(conn, 401))

  defp replace_header(headers, name, value),
    do: [{name, value} | Enum.reject(headers, &(elem(&1, 0) == name))]

  defp replace_content_type(headers, value), do: replace_header(headers, "content-type", value)
  defp nonce, do: :crypto.strong_rand_bytes(32)
  defp now, do: DateTime.to_unix(Renga.Time.utc_now_ms())

  defp observation_payload(source),
    do: %{
      "observation_id" => "key-observation",
      "observed_at" => "2026-07-31T12:00:00Z",
      "source" => %{"kind" => "host_agent", "source_id" => source.name},
      "resources" => [
        %{
          "kind" => "server",
          "identifiers" => %{"hostname" => "key-host"},
          "attributes" => %{"hostname" => "key-host"},
          "interfaces" => [],
          "components" => []
        }
      ]
    }

  defp event!(fixture, kind, occurred_at) do
    %CredentialEvent{
      organization_id: fixture.organization.id,
      agent_credential_id: fixture.credential.id
    }
    |> CredentialEvent.changeset(%{kind: kind, occurred_at: occurred_at})
    |> Repo.insert!()
  end

  defp second_fixture do
    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Other",
        slug: "other-#{System.unique_integer([:positive])}"
      })

    user = user_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "admin"})

    scope =
      Accounts.scope_for(organization, %{user: user, membership_id: membership.id})

    {:ok, {source, _}} =
      Inventory.create_source_with_token(scope, %{kind: "host_agent", name: "other"})

    agent =
      %Agent{
        organization_id: organization.id,
        source_id: source.id,
        installation_id: @other_installation_id
      }
      |> Agent.changeset(%{name: "other", registered_at: Renga.Time.utc_now_ms()})
      |> Repo.insert!()

    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    credential =
      %AgentCredential{
        organization_id: organization.id,
        source_id: source.id,
        agent_id: agent.id,
        credential_id: :crypto.strong_rand_bytes(32),
        public_key: public_key,
        key_thumbprint: :crypto.hash(:sha256, public_key)
      }
      |> AgentCredential.changeset(%{
        expires_at: DateTime.add(Renga.Time.utc_now_ms(), 3_600, :second)
      })
      |> Repo.insert!()

    %{
      organization: organization,
      scope: scope,
      source: source,
      agent: agent,
      credential: credential,
      private_key: private_key
    }
  end

  defp concurrently(count, fun), do: concurrently(List.duplicate(fun, count))

  defp concurrently(funs) do
    owner = self()

    tasks =
      Enum.map(funs, fn fun ->
        Task.async(fn ->
          send(owner, {:ready, self()})
          receive do: (:go -> fun.())
        end)
      end)

    Enum.each(tasks, fn task ->
      assert_receive {:ready, pid} when pid == task.pid
      Sandbox.allow(Repo, owner, task.pid)
    end)

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 5_000))
  end

  defp action_agent_function(:revoke), do: :revoke_agent_credential
  defp action_agent_function(:quarantine), do: :quarantine_agent_credential
end
