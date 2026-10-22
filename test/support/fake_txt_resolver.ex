defmodule Renga.FakeTxtResolver do
  @moduledoc """
  DNS TXT lookups for organization domain verification in tests
  (`Renga.Accounts.OrganizationDomains`). A name has no records unless the
  test process, or a process it started such as a LiveView, says otherwise:

      FakeTxtResolver.put("_renga-verification.example.com", ["renga-verification=..."])
      FakeTxtResolver.put("_renga-verification.example.com", {:error, :timeout})
  """

  @doc "Makes `name` answer `answer`: a list of values or `{:error, reason}`."
  def put(name, answer), do: Process.put({__MODULE__, name}, answer)

  @doc false
  def lookup(name) do
    [self() | Process.get(:"$callers", [])]
    |> Enum.find_value(fn pid -> answer(pid, name) end)
    |> case do
      nil -> {:error, :nxdomain}
      {:error, _reason} = error -> error
      values -> {:ok, values}
    end
  end

  defp answer(pid, name) when pid == self(), do: Process.get({__MODULE__, name})

  defp answer(pid, name) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> List.keyfind(dictionary, {__MODULE__, name}, 0) |> value()
      nil -> nil
    end
  end

  defp value({_key, answer}), do: answer
  defp value(nil), do: nil
end
