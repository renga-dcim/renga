defmodule Renga.DCIM.DesiredPlacement do
  @moduledoc "Operator placement intent, kept separate from current rack occupancy."
  use Renga.DCIM.Placement, table: "desired_placements"
end
