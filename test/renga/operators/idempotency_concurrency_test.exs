defmodule Renga.Operators.IdempotencyConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts.Organization
  alias Renga.DeploymentAudit.Event
  alias Renga.Operators
  alias Renga.Operators.Idempotency
  alias Renga.Operators.Organizations
  alias Renga.Repo

  @timeout 5_000

  test "concurrent requests converge on one organization and one audit event" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    suffix = System.unique_integer([:positive])
    slug = "concurrent-#{suffix}"
    token_context = Renga.DeploymentAudit.operator("test")
    first_request_id = Ecto.UUID.generate()
    second_request_id = Ecto.UUID.generate()

    {:ok, {token, _plaintext}} =
      Operators.create_token(
        %{name: "concurrent-idempotency-#{suffix}", scopes: ["organizations:write"]},
        token_context
      )

    idempotency = %Idempotency{
      token_id: token.id,
      method: "POST",
      route: "/operator/v1/organizations",
      key: "same-key",
      digest: Idempotency.digest(%{"name" => "Concurrent", "slug" => slug}),
      status: 201,
      render: &%{"id" => &1.id},
      expires_at: Idempotency.expiration()
    }

    parent = self()

    first =
      request(parent, fn ->
        Organizations.create(
          %{"name" => "Concurrent", "slug" => slug},
          Renga.DeploymentAudit.token(token, first_request_id),
          idempotency
        )
      end)

    second =
      request(parent, fn ->
        Organizations.create(
          %{"name" => "Concurrent", "slug" => slug},
          Renga.DeploymentAudit.token(token, second_request_id),
          idempotency
        )
      end)

    assert_receive {:ready, first_pid}, @timeout
    assert_receive {:ready, second_pid}, @timeout
    send(first_pid, :go)
    send(second_pid, :go)

    results = [Task.await(first, @timeout), Task.await(second, @timeout)]

    assert Enum.count(results, &match?({:ok, %Organization{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :replayed})) == 1
    assert Repo.aggregate(where(Organization, slug: ^slug), :count) == 1
    assert Repo.aggregate(
             where(Idempotency.Key, [key], key.operator_token_id == ^token.id),
             :count
           ) == 1

    assert Repo.all(
             from event in Event,
               where: event.operation == "organization.create",
               select: {event.outcome, event.reason}
           ) == [{"succeeded", nil}]

    Repo.delete_all(
      from event in Event,
        where:
          event.invocation_id in ^[
            token_context.invocation_id,
            first_request_id,
            second_request_id
          ]
    )

    Repo.delete_all(where(Organization, [organization], organization.slug == ^slug))
    Repo.delete!(token)
    Sandbox.checkin(Repo)
  end

  defp request(parent, operation) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      send(parent, {:ready, self()})

      try do
        receive do
          :go -> operation.()
        after
          @timeout -> raise "timed out waiting to start idempotent request"
        end
      after
        Sandbox.checkin(Repo)
      end
    end)
  end
end
