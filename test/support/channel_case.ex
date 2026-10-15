defmodule RengaWeb.ChannelCase do
  @moduledoc """
  The test case for channel tests: `Phoenix.ChannelTest` against the app
  endpoint, with the SQL sandbox set up like every other case.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import RengaWeb.ChannelCase

      @endpoint RengaWeb.Endpoint
    end
  end

  setup tags do
    Renga.DataCase.setup_sandbox(tags)
    :ok
  end
end
