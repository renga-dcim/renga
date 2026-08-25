defmodule Renga.DCIM.CurrentPlacement do
  @moduledoc "Reconciled physical placement that drives canonical rack occupancy."
  use Renga.DCIM.Placement, table: "current_placements"
end
