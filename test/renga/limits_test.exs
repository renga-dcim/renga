defmodule Renga.LimitsTest do
  use Renga.DataCase, async: true

  import Renga.InventoryFixtures

  alias Renga.Limits

  test "an organization gets the deployment default until an operator overrides it" do
    organization = organization_fixture()
    other = organization_fixture()

    assert Limits.get(organization.id, :job_creation_rate) == 10_000

    :ok = Limits.set(organization, :job_creation_rate, 600)
    assert Limits.get(organization.id, :job_creation_rate) == 600
    assert Limits.get(other.id, :job_creation_rate) == 10_000

    :ok = Limits.set(organization, :job_creation_rate, 700)
    assert Limits.get(organization.id, :job_creation_rate) == 700

    :ok = Limits.clear(organization, :job_creation_rate)
    assert Limits.get(organization.id, :job_creation_rate) == 10_000
  end

  test "list/1 says where each value comes from" do
    organization = organization_fixture()
    :ok = Limits.set(organization, :job_creation_rate, 5)

    assert [%{name: :job_creation_rate, value: 5, default: 10_000, overridden?: true}] =
             Limits.list(organization)
  end

  test "parse_name/1 accepts only known limits" do
    assert Limits.parse_name("job_creation_rate") == {:ok, :job_creation_rate}
    assert Limits.parse_name("anything_else") == :error
  end
end
