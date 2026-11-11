defmodule RengaWeb.UsageTelemetryTest do
  use RengaWeb.ConnCase, async: true
  import Renga.JobsFixtures

  setup do
    id = "usage-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      [
        [:renga, :organization, :database],
        [:renga, :intake, :request],
        [:renga, :intake, :rejected],
        [:renga, :request, :rejected]
      ],
      &__MODULE__.record/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  def record(event, measurements, metadata, pid), do: send(pid, {event, measurements, metadata})

  test "database attribution is restored after success and failure" do
    organization_id = Ecto.UUID.generate()

    Renga.UsageTelemetry.with_organization(organization_id, fn ->
      Renga.Repo.query!("SELECT 42")
    end)

    assert_receive {[:renga, :organization, :database], %{total_time: time},
                    %{organization_id: ^organization_id}}

    assert time > 0
    assert Renga.UsageTelemetry.organization_id() == nil

    assert_raise RuntimeError, fn ->
      Renga.UsageTelemetry.with_organization(organization_id, fn -> raise "failure" end)
    end

    assert Renga.UsageTelemetry.organization_id() == nil
  end

  test "intake measures actual parsed bytes and rejected requests", %{conn: conn} do
    %{scope: scope, organization: organization} = job_organization_fixture()
    {:ok, {_key, token}} = Renga.Inventory.create_intake_api_key(scope, %{name: "telemetry test"})
    body = ~s({"invalid":"#{String.duplicate("x", 91)}"})
    organization_id = organization.id

    # Another async request can emit the same event before this request finishes.
    :telemetry.execute(
      [:renga, :intake, :request],
      %{count: 1, bytes: 0},
      %{organization_id: Ecto.UUID.generate(), status: 422}
    )

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-renga-installation-id", Ecto.UUID.generate())
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/observations", body)
    |> valid_api_response(422)

    assert_receive {[:renga, :intake, :request], %{count: 1, bytes: bytes},
                    %{organization_id: ^organization_id, status: 422}}

    assert bytes == byte_size(body)

    assert Renga.UsageTelemetry.organization_id() == nil
  end

  test "browser rejections retain their organization attribution", %{conn: conn} do
    %{scope: scope, organization: organization} = job_organization_fixture()

    :ok =
      Renga.Limits.set(organization, [http_user_rate: 0], Renga.DeploymentAudit.operator("test"))

    response =
      conn
      |> log_in_user(scope.user)
      |> put_session(:current_organization_id, organization.id)
      |> get(~p"/settings/limits")

    assert response.status == 429
    organization_id = organization.id

    assert_receive {[:renga, :request, :rejected], %{count: 1},
                    %{organization_id: ^organization_id}}

    assert Renga.UsageTelemetry.organization_id() == nil
  end
end
