defmodule Renga.Jobs.RegistryTest do
  use ExUnit.Case, async: true

  alias Renga.Jobs.Capabilities.InventoryCollect
  alias Renga.Jobs.Capability
  alias Renga.Jobs.Registry

  describe "parse_key/1" do
    test "splits a versioned capability" do
      assert {:ok, {"inventory.collect", 1}} = Capability.parse_key("inventory.collect@1")
      assert {:ok, {"vm.power_on", 12}} = Capability.parse_key("vm.power_on@12")
    end

    test "rejects unversioned reporting capabilities and malformed keys" do
      for key <- [
            "host.inventory",
            "inventory.collect@0",
            "inventory.collect@v1",
            "collect@1",
            ""
          ] do
        assert Capability.parse_key(key) == :error
      end
    end
  end

  test "fetches a capability by its name@version key" do
    assert {:ok, InventoryCollect} = Registry.fetch("inventory.collect@1")
    assert {:error, :unknown_capability} = Registry.fetch("inventory.collect@2")
    assert {:error, :unknown_capability} = Registry.fetch(nil)
  end

  test "groups keys by risk class" do
    assert "inventory.collect@1" in Registry.keys_with_risk(:observe)
    refute "test.restart@1" in Registry.keys_with_risk(:observe)
    assert "test.restart@1" in Registry.keys_with_risk(:operate)
  end

  describe "inventory.collect@1" do
    test "is a harmless, idempotent observation" do
      assert InventoryCollect.risk_class() == :observe
      assert InventoryCollect.retry_class() == :idempotent
      assert InventoryCollect.output_limit_bytes() == 64 * 1024
      refute InventoryCollect.sensitive_output?()
    end

    test "takes no parameters" do
      assert InventoryCollect.parameters_changeset(%{}).valid?
      refute InventoryCollect.parameters_changeset(%{"script" => "rm -rf /"}).valid?
    end

    test "returns the observation it produced" do
      id = Ecto.UUID.generate()

      assert {:ok, %{observation_id: ^id}} =
               %{"observation_id" => id}
               |> InventoryCollect.result_changeset()
               |> Ecto.Changeset.apply_action(:validate)

      refute InventoryCollect.result_changeset(%{}).valid?
      refute InventoryCollect.result_changeset(%{"observation_id" => "nope"}).valid?
      assert InventoryCollect.describe_result(%{"observation_id" => id}) =~ id
    end
  end
end
