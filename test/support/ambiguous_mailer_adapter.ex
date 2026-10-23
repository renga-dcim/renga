defmodule Renga.AmbiguousMailerAdapter do
  @moduledoc false

  use Swoosh.Adapter

  @impl true
  def deliver(email, _config) do
    send(self(), {:ambiguous_email, email})
    {:error, :provider_timeout}
  end
end
