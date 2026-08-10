defmodule RengaWeb.Api.V1.EnrollmentControllerTest do
  use RengaWeb.ConnCase, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Enrollment
  alias Renga.Enrollment.EnrollmentChallenge
  alias Renga.Repo

  setup do
    fixture = enrollment_fixture()
    %{fixture: fixture}
  end

  test "challenge route is public and returns the proof contract", %{conn: conn, fixture: fixture} do
    conn = post(conn, ~p"/api/v1/enrollment/challenges", challenge_params(fixture))
    body = json_response(conn, 200)

    assert %{
             "challenge_id" => _,
             "nonce" => _,
             "expires_at" => _,
             "proof" => %{
               "version" => "renga-enrollment-proof-v1",
               "algorithm" => "Ed25519",
               "canonicalization" => "renga-canonical-v1"
             }
           } = body
  end

  test "malformed and unknown profiles return the same generic 404", %{
    conn: conn,
    fixture: fixture
  } do
    for profile <- ["", "unknown"] do
      response =
        conn
        |> recycle()
        |> post(~p"/api/v1/enrollment/challenges", %{
          challenge_params(fixture)
          | "profile" => profile
        })
        |> json_response(404)

      assert response == %{"status" => "denied", "error" => "enrollment_not_available"}
    end
  end

  test "valid challenge and attempt return only the safe accepted result", %{
    conn: conn,
    fixture: fixture
  } do
    {contract, challenge} = request_challenge(conn, fixture)
    params = attempt_params(fixture, contract, challenge)

    response =
      conn |> recycle() |> post(~p"/api/v1/enrollment/attempts", params) |> json_response(200)

    assert %{
             "status" => "accepted",
             "source_id" => _,
             "agent_id" => _,
             "credential_id" => _,
             "assignments" => %{},
             "grants" => []
           } = response

    refute Map.has_key?(response, "evidence")
    refute Map.has_key?(response, "public_key")
    refute Map.has_key?(response, "token")

    refute response["credential_id"] in [
             fixture.secret.secret,
             fixture.secret.public_id,
             Base.url_encode64(fixture.public, padding: false)
           ]
  end

  test "bad proof returns generic 422 without sensitive values", %{conn: conn, fixture: fixture} do
    {contract, challenge} = request_challenge(conn, fixture)

    params =
      attempt_params(fixture, contract, challenge)
      |> Map.put("proof", Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false))

    response =
      conn |> recycle() |> post(~p"/api/v1/enrollment/attempts", params) |> json_response(422)

    assert response == %{"status" => "denied", "error" => "enrollment_denied"}
  end

  test "a changed terminal request returns generic 409", %{conn: conn, fixture: fixture} do
    {contract, challenge} = request_challenge(conn, fixture)
    params = attempt_params(fixture, contract, challenge)

    assert %{"status" => "accepted"} =
             conn
             |> recycle()
             |> post(~p"/api/v1/enrollment/attempts", params)
             |> json_response(200)

    changed = attempt_params(fixture, contract, challenge, ["changed"])

    response =
      conn |> recycle() |> post(~p"/api/v1/enrollment/attempts", changed) |> json_response(409)

    assert response == %{"status" => "denied", "error" => "submission_conflict"}
  end

  defp enrollment_fixture do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "owner"})
    scope = Accounts.scope_for_user(user, organization.id)

    policy_document = %{
      "rule" => %{
        "id" => "manual",
        "attribute" => ["verified", "assurance"],
        "operator" => "eq",
        "value" => "manual_grant"
      }
    }

    {:ok, policy} = Enrollment.create_policy(scope, %{name: "api", document: policy_document})

    {:ok, verifier} =
      Enrollment.create_verifier_configuration(scope, %{
        name: "manual",
        kind: "manual",
        subject_cardinality: "singleton",
        configuration: %{}
      })

    {:ok, profile} =
      Enrollment.create_profile(scope, %{
        selector: "public",
        name: "Public",
        enrollment_policy_id: policy.id,
        verifier_configuration_id: verifier.id
      })

    {:ok, _grant, secret} = Enrollment.create_manual_grant(scope, profile.id)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      organization: organization,
      profile: profile,
      secret: secret,
      public: public,
      private: private,
      installation_id: Ecto.UUID.generate()
    }
  end

  defp challenge_params(f),
    do: %{
      "organization" => f.organization.slug,
      "profile" => f.profile.selector,
      "installation_id" => f.installation_id,
      "public_key" => Base.url_encode64(f.public, padding: false)
    }

  defp request_challenge(conn, fixture) do
    contract =
      conn
      |> recycle()
      |> post(~p"/api/v1/enrollment/challenges", challenge_params(fixture))
      |> json_response(200)

    {contract, Repo.get!(EnrollmentChallenge, contract["challenge_id"])}
  end

  defp attempt_params(fixture, contract, challenge, requested \\ []) do
    nonce = Base.url_decode64!(contract["nonce"], padding: false)

    evidence = %{
      "kind" => "manual",
      "public_id" => fixture.secret.public_id,
      "secret" => fixture.secret.secret
    }

    metadata = %{"client" => "test"}
    transcript = Enrollment.proof_transcript(challenge, nonce, evidence, requested, metadata)
    proof = :crypto.sign(:eddsa, :none, transcript, [fixture.private, :ed25519])

    %{
      "challenge_id" => challenge.id,
      "nonce" => contract["nonce"],
      "evidence" => evidence,
      "requested_capabilities" => requested,
      "metadata" => metadata,
      "proof" => Base.url_encode64(proof, padding: false)
    }
  end
end
