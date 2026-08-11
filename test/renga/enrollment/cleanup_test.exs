defmodule Renga.Enrollment.CleanupTest do
  use Renga.DataCase, async: false

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Enrollment
  alias Renga.Enrollment.{Cleanup, EnrollmentAttempt, EnrollmentChallenge, EnrollmentReplay}
  alias Renga.Repo

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "owner"})
    scope = Accounts.scope_for_user(user, organization.id)

    {:ok, policy} =
      Enrollment.create_policy(scope, %{
        name: "cleanup",
        document: %{
          "rule" => %{
            "id" => "deny",
            "attribute" => ["server", "profile"],
            "operator" => "eq",
            "value" => "never"
          }
        }
      })

    {:ok, verifier} =
      Enrollment.create_verifier_configuration(scope, %{
        name: "cleanup",
        kind: "manual",
        subject_cardinality: "singleton",
        configuration: %{}
      })

    {:ok, profile} =
      Enrollment.create_profile(scope, %{
        selector: "cleanup-#{System.unique_integer([:positive])}",
        name: "Cleanup",
        enrollment_policy_id: policy.id,
        verifier_configuration_id: verifier.id
      })

    {public, _private} = :crypto.generate_key(:eddsa, :ed25519)
    fixture = %{organization: organization, verifier: verifier, profile: profile, public: public}
    fixture = Map.put(fixture, :challenge, challenge!(fixture))
    %{fixture: fixture}
  end

  test "cleanup removes expired replay protection but retains it before expiry", %{
    fixture: fixture
  } do
    expired = replay!(fixture, DateTime.add(Renga.Time.utc_now_ms(), -1, :second))
    unexpired = replay!(fixture, DateTime.add(Renga.Time.utc_now_ms(), 60, :second))

    assert %{replays: 1} = Cleanup.cleanup_once()
    refute Repo.get(EnrollmentReplay, expired.id)
    assert Repo.get(EnrollmentReplay, unexpired.id)
  end

  test "cleanup removes only expired open unsubmitted challenges", %{fixture: fixture} do
    past = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)
    open = fixture.challenge
    terminal = challenge!(fixture)
    digest = :crypto.strong_rand_bytes(32)

    Repo.update_all(from(c in EnrollmentChallenge, where: c.id == ^open.id),
      set: [expires_at: past]
    )

    Repo.update_all(from(c in EnrollmentChallenge, where: c.id == ^terminal.id),
      set: [
        expires_at: past,
        status: "denied",
        terminal_at: past,
        submission_digest: digest,
        safe_result: %{status: "denied"}
      ]
    )

    assert %{challenges: 1} = Cleanup.cleanup_once()
    refute Repo.get(EnrollmentChallenge, open.id)
    assert Repo.get(EnrollmentChallenge, terminal.id)
  end

  test "cleanup preserves an expired challenge referenced by an attempt", %{fixture: fixture} do
    challenge = fixture.challenge
    past = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

    Repo.update_all(from(c in EnrollmentChallenge, where: c.id == ^challenge.id),
      set: [expires_at: past]
    )

    %EnrollmentAttempt{
      organization_id: fixture.organization.id,
      enrollment_challenge_id: challenge.id,
      enrollment_policy_id: challenge.enrollment_policy_id,
      verifier_configuration_id: fixture.verifier.id
    }
    |> EnrollmentAttempt.changeset(%{
      evidence_digest: :crypto.strong_rand_bytes(32),
      status: "received"
    })
    |> Repo.insert!()

    assert %{challenges: 0} = Cleanup.cleanup_once()
    assert Repo.get(EnrollmentChallenge, challenge.id)
  end

  test "cleanup obeys batch and maximum batch bounds", %{fixture: fixture} do
    old = Application.get_env(:renga, Cleanup)

    Application.put_env(:renga, Cleanup,
      batch_size: 2,
      max_batches_per_tick: 2,
      interval: :timer.hours(1)
    )

    on_exit(fn -> Application.put_env(:renga, Cleanup, old) end)
    past = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

    rows = for _ <- 1..6, do: replay!(fixture, past)

    assert %{replays: 4} = Cleanup.cleanup_once()
    assert Enum.count(rows, &Repo.get(EnrollmentReplay, &1.id)) == 2
  end

  test "cleanup worker is supervised after Repo" do
    children = Supervisor.which_children(Renga.Supervisor)

    assert {Renga.Enrollment.Cleanup, _, :worker, _} =
             List.keyfind(children, Renga.Enrollment.Cleanup, 0)

    assert Process.whereis(Renga.Repo)
  end

  test "cleanup has global and profile-cap partial indexes" do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'enrollment_challenges' AND indexname = ANY($1)",
        [
          [
            "enrollment_challenges_global_open_expiry_index",
            "enrollment_challenges_profile_open_expiry_index"
          ]
        ]
      )

    assert length(rows) == 2

    assert Enum.all?(rows, fn [_name, definition] ->
             definition =~ "(status)::text = 'open'::text" and
               definition =~ "submission_digest IS NULL"
           end)
  end

  defp replay!(fixture, expires_at) do
    %EnrollmentReplay{
      organization_id: fixture.organization.id,
      verifier_configuration_id: fixture.verifier.id
    }
    |> EnrollmentReplay.changeset(%{
      kind: "oidc_digest",
      value_hash: :crypto.strong_rand_bytes(32),
      expires_at: expires_at
    })
    |> Repo.insert!()
  end

  defp challenge!(fixture) do
    {:ok, contract} =
      Enrollment.create_challenge(
        fixture.organization.slug,
        fixture.profile.selector,
        Ecto.UUID.generate(),
        fixture.public
      )

    Repo.get!(EnrollmentChallenge, contract.id)
  end
end
