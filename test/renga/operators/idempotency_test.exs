defmodule Renga.Operators.IdempotencyTest do
  use Renga.DataCase, async: true

  alias Renga.Operators.Idempotency
  alias Renga.Repo

  setup do
    {:ok, {token, _plaintext}} =
      Renga.Operators.create_token(
        %{
          name: "idempotency-#{System.unique_integer([:positive])}",
          scopes: ["organizations:write"]
        },
        Renga.DeploymentAudit.operator("test")
      )

    %{token: token}
  end

  defp idempotency(token, params, key \\ "k1") do
    %Idempotency{
      token_id: token.id,
      method: "POST",
      route: "/operator/v1/organizations",
      key: key,
      digest: Idempotency.digest(params),
      status: 201,
      render: &%{"value" => &1}
    }
  end

  defp complete(idempotency, result) do
    Repo.transaction(fn ->
      :ok = Idempotency.begin(idempotency)
      Idempotency.finish!(idempotency, result)
    end)
  end

  test "digests ignore key order and key types" do
    assert Idempotency.digest(%{"a" => 1, "b" => %{"c" => 2}}) ==
             Idempotency.digest(%{b: %{c: 2}, a: 1})

    refute Idempotency.digest(%{"a" => 1}) == Idempotency.digest(%{"a" => 2})
  end

  test "keys are 1 to 255 visible ASCII characters" do
    assert Idempotency.valid_key?("signup:organization:12")
    assert Idempotency.valid_key?(String.duplicate("k", 255))
    refute Idempotency.valid_key?("")
    refute Idempotency.valid_key?("has space")
    refute Idempotency.valid_key?(String.duplicate("k", 256))
    refute Idempotency.valid_key?(nil)
  end

  test "returns a completed response for the same request", %{token: token} do
    idempotency = idempotency(token, %{"slug" => "acme"})
    assert Idempotency.fetch(idempotency) == :none

    {:ok, :ok} = complete(idempotency, "done")

    assert {:ok, {201, %{"value" => "done"}, expires_at}} = Idempotency.fetch(idempotency)
    assert DateTime.diff(expires_at, DateTime.utc_now(), :hour) in 23..24
  end

  test "a different request under the same key is a conflict", %{token: token} do
    {:ok, :ok} = complete(idempotency(token, %{"slug" => "acme"}), "done")

    assert Idempotency.fetch(idempotency(token, %{"slug" => "other"})) == {:error, :conflict}
  end

  test "begin notices a request that completed meanwhile", %{token: token} do
    idempotency = idempotency(token, %{"slug" => "acme"})
    {:ok, :ok} = complete(idempotency, "done")

    assert {:ok, {:error, :replayed}} =
             Repo.transaction(fn -> Idempotency.begin(idempotency) end)
  end

  test "an expired key is reused", %{token: token} do
    idempotency = idempotency(token, %{"slug" => "acme"})
    {:ok, :ok} = complete(idempotency, "first")

    Repo.update_all(Idempotency.Key,
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert Idempotency.fetch(idempotency) == :none

    {:ok, :ok} = complete(idempotency, "second")
    assert {:ok, {201, %{"value" => "second"}, _}} = Idempotency.fetch(idempotency)
  end

  test "forget! lets the operation run again", %{token: token} do
    idempotency = idempotency(token, %{"slug" => "acme"})
    {:ok, :ok} = complete(idempotency, "done")

    :ok = Idempotency.forget!(idempotency)
    assert Idempotency.fetch(idempotency) == :none
  end

  test "release commands pass no idempotency" do
    assert Idempotency.begin(nil) == :ok
    assert Idempotency.finish!(nil, "anything") == :ok
  end
end
