defmodule Renga.FailingMailerAdapter do
  @moduledoc false

  use Swoosh.Adapter

  @impl true
  def deliver(_email, _config), do: {:error, :unavailable}
end
