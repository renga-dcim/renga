defmodule RengaWeb.Format do
  @moduledoc """
  Display formatting shared across pages, so the same instant reads the same
  way in a list row, an object header, and a provenance popover.
  """

  @doc """
  Compact age for status signals and "seen" columns: `now`, `4m`, `3h`,
  `2d`, `5w`. `nil` means never.
  """
  def age(datetime, now \\ DateTime.utc_now())
  def age(nil, _now), do: nil

  def age(%DateTime{} = datetime, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, datetime), 0)

    cond do
      seconds < 60 -> "now"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h"
      seconds < 14 * 86_400 -> "#{div(seconds, 86_400)}d"
      true -> "#{div(seconds, 7 * 86_400)}w"
    end
  end

  @doc "Absolute UTC time, for titles and details: `2026-08-07 10:00 UTC`."
  def datetime(nil), do: "Never"
  def datetime(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  @doc "Words for a snake_case identifier: `virtual_machine` → `virtual machine`."
  def humanize(value) when is_binary(value), do: String.replace(value, "_", " ")
  def humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()
end
