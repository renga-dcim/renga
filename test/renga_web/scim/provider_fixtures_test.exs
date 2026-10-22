defmodule RengaWeb.Scim.ProviderFixturesTest do
  @moduledoc """
  Replays Okta's and Microsoft Entra ID's provisioning requests, in the
  shapes their SCIM documentation publishes, against the endpoints. Each
  step in test/support/scim/<provider>.json is one request; `{{name}}`
  placeholders take ids that earlier responses returned.
  """

  use RengaWeb.ConnCase, async: true

  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]
  import Renga.ScimFixtures

  @fixtures Path.expand("../../support/scim", __DIR__)

  setup %{conn: conn} do
    owner = member_scope(organization_fixture(), "owner")
    {_token, value} = scim_token_fixture(owner, scim_connection_fixture(owner))

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> value)
      |> put_req_header("content-type", "application/scim+json")
      |> put_req_header("accept", "application/scim+json")

    %{conn: conn}
  end

  for provider <- ~w(okta entra) do
    @tag provider: provider
    test "#{provider}'s provisioning requests", %{conn: conn, provider: provider} do
      steps = @fixtures |> Path.join("#{provider}.json") |> File.read!() |> Jason.decode!()

      Enum.reduce(steps, %{}, fn step, captured ->
        replay(conn, step, captured)
      end)
    end
  end

  defp replay(conn, step, captured) do
    path = substitute(step["path"], captured)
    body = if step["body"], do: step["body"] |> substitute(captured) |> Jason.encode!(), else: ""
    label = "#{step["method"]} #{path}"

    response =
      case step["method"] do
        "GET" -> get(conn, path)
        "POST" -> post(conn, path, body)
        "PUT" -> put(conn, path, body)
        "PATCH" -> patch(conn, path, body)
        "DELETE" -> delete(conn, path)
      end

    assert response.status == step["status"], "#{label}: #{response.resp_body}"
    decoded = if response.resp_body == "", do: %{}, else: Jason.decode!(response.resp_body)

    for {key, expected} <- step["expect"] || %{} do
      assert decoded[key] == substitute(expected, captured), "#{label}: #{key}"
    end

    for key <- step["absent"] || [] do
      refute Map.has_key?(decoded, key), "#{label}: #{key} should not be returned"
    end

    if members = step["expect_members"] do
      assert Enum.map(decoded["members"], & &1["value"]) == substitute(members, captured), label
    end

    for {name, key} <- step["capture"] || %{}, into: captured, do: {name, decoded[key]}
  end

  defp substitute(value, captured) when is_binary(value) do
    Regex.replace(~r/\{\{(\w+)\}\}/, value, fn _match, name -> Map.fetch!(captured, name) end)
  end

  defp substitute(value, captured) when is_list(value),
    do: Enum.map(value, &substitute(&1, captured))

  defp substitute(value, captured) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, substitute(item, captured)} end)

  defp substitute(value, _captured), do: value
end
