defmodule Renga.Jobs.SignedLeasesTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Inventory.InstallationKeys
  alias Renga.Jobs
  alias Renga.Jobs.SignedLeases
  alias Renga.Jobs.TargetBindings

  @collect "inventory.collect@1"
  @restart "test.restart@1"

  setup do
    %{organization: organization} = context = job_organization_fixture()

    organization
    |> Ecto.Changeset.change(
      settings: %{"jobs" => %{"allowed_capabilities" => [@collect, @restart]}}
    )
    |> Repo.update!()

    agent = agent_fixture(organization, [@collect, @restart])
    bound = target_binding_fixture(organization, agent)

    {:ok, job} =
      Jobs.create_system_job(organization.id, agent.id, @restart, %{"service" => "sshd"},
        resource_id: bound.resource.id
      )

    Map.merge(context, %{agent: agent, bound: bound, job: job})
  end

  defp offer(%{system_scope: scope, agent: agent}) do
    {:ok, offers} = SignedLeases.offer(scope, agent, [@restart], 1)
    offers
  end

  defp claim(context, offer, signature) do
    SignedLeases.claim(
      context.system_scope,
      context.agent,
      offer.job.id,
      offer.lease_token,
      offer.nonce,
      signature
    )
  end

  test "privileged jobs never lease on the intake key alone", context do
    assert {:ok, []} = Jobs.lease_jobs(context.system_scope, context.agent, [@restart], 5)
  end

  test "a signed claim leases the offered job with the offered token", context do
    [offer] = offer(context)
    assert offer.job.id == context.job.id
    assert offer.job.state == "queued"

    signature = sign_offer(offer, context.agent, context.bound.private_key)
    assert {:ok, {job, token}} = claim(context, offer, signature)
    assert job.state == "leased"
    assert token == offer.lease_token
    assert is_nil(job.offer_nonce)

    assert {:ok, _job} =
             Jobs.report(context.system_scope, context.agent, job.id, token, "started", %{})
  end

  test "refuses a signature from any other key", context do
    [offer] = offer(context)
    {_public, stranger} = :crypto.generate_key(:eddsa, :ed25519)

    assert {:error, :signature_invalid} =
             claim(context, offer, sign_offer(offer, context.agent, stranger))

    assert Repo.reload!(context.job).state == "queued"
  end

  test "refuses a signature over different fields", context do
    [offer] = offer(context)
    tampered = %{offer | nonce: offer.nonce <> "x"}
    signature = sign_offer(tampered, context.agent, context.bound.private_key)

    assert {:error, :signature_invalid} = claim(context, offer, signature)
  end

  test "a later offer replaces an earlier one", context do
    [first] = offer(context)
    [second] = offer(context)
    signature = sign_offer(first, context.agent, context.bound.private_key)

    assert {:error, :offer_invalid} = claim(context, first, signature)

    assert {:ok, {_job, _token}} =
             claim(context, second, sign_offer(second, context.agent, context.bound.private_key))
  end

  test "an expired offer cannot be claimed", context do
    [offer] = offer(context)

    context.job
    |> Ecto.Changeset.change(offer_expires_at: DateTime.add(Renga.Time.utc_now_ms(), -1))
    |> Repo.update!()

    signature = sign_offer(offer, context.agent, context.bound.private_key)
    assert {:error, :offer_invalid} = claim(context, offer, signature)
  end

  test "another installation cannot claim the offer", context do
    [offer] = offer(context)
    other = agent_fixture(context.organization, [@restart])

    assert {:error, :not_found} =
             SignedLeases.claim(
               context.system_scope,
               other,
               offer.job.id,
               offer.lease_token,
               offer.nonce,
               sign_offer(offer, other, context.bound.private_key)
             )
  end

  test "a job whose binding changed after the offer fails at the claim", context do
    [offer] = offer(context)
    signature = sign_offer(offer, context.agent, context.bound.private_key)

    # Bypasses revoke/2, which would already fail the queued job.
    context.bound.binding
    |> Ecto.Changeset.change(
      status: "revoked",
      revoked_at: Renga.Time.utc_now_ms(),
      revoked_reason: "revoked"
    )
    |> Repo.update!()

    assert {:ok, {:failed, :binding_changed}} = claim(context, offer, signature)
    assert Repo.reload!(context.job).failure_reason == "binding_changed"
  end

  test "a pending key gets no offers and leaves the job queued", context do
    {public_key, _private} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, _key} =
      Repo.transaction(fn ->
        InstallationKeys.present!(
          context.agent,
          %{algorithm: "ed25519", public_key: public_key},
          Renga.Time.utc_now_ms()
        )
      end)

    # Replacing the key revoked the binding, so the job failed rather than wait.
    assert offer(context) == []
    assert Repo.reload!(context.job).failure_reason == "binding_changed"
  end

  test "offers only jobs whose capability the organization still allows", context do
    context.organization
    |> Ecto.Changeset.change(settings: %{"jobs" => %{"allowed_capabilities" => [@collect]}})
    |> Repo.update!()

    assert offer(context) == []
    assert Repo.reload!(context.job).failure_reason == "capability_not_allowed"
    assert TargetBindings.current(context.system_scope, context.bound.resource.id)
  end
end
