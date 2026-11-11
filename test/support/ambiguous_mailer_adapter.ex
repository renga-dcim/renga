defmodule Renga.AmbiguousMailerAdapter do
  @moduledoc false

  use Swoosh.Adapter

  @impl true
  def deliver(email, _config) do
    # Match Swoosh's test adapter when delivery runs in a supervised batch.
    for pid <- Enum.uniq([self() | List.wrap(Process.get(:"$callers"))]),
        do: send(pid, {:ambiguous_email, email})

    {:error, :provider_timeout}
  end
end
