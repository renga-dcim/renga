defmodule Renga.Power.Paths.Path do
  @moduledoc "One port's power chain: the outlets it passes, then a feed or a stop."

  defstruct [:port, outlets: [], feed: nil, stop: nil]
end
