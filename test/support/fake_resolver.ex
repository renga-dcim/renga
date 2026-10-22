defmodule Renga.FakeResolver do
  @moduledoc """
  Name resolution for organization provider requests in tests
  (`Renga.Accounts.OIDC.Destinations`). Every name resolves to one public
  address unless the test process says otherwise:

      FakeResolver.put("idp.example.com", [{127, 0, 0, 1}])
  """

  @public {93, 184, 215, 14}

  @doc "Makes `host` resolve to `addresses` for this test process."
  def put(host, addresses), do: Process.put({__MODULE__, host}, addresses)

  @doc false
  def resolve(host) do
    case Process.get({__MODULE__, host}) do
      nil -> {:ok, [@public]}
      addresses -> {:ok, addresses}
    end
  end
end
