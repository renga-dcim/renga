defmodule Renga.Time do
  @moduledoc """
  Timestamp helpers for values stored in millisecond-precision PostgreSQL columns.

  Ecto's `:utc_datetime_usec` type expects six-digit precision metadata, while
  our database columns intentionally store only millisecond precision. These
  helpers keep the timestamp value millisecond-aligned without giving Ecto a
  three-digit precision struct it will reject.
  """

  def utc_now_ms do
    DateTime.utc_now(:microsecond)
    |> floor_to_millisecond()
  end

  def from_unix_ms!(unix_ms) when is_integer(unix_ms) do
    unix_ms
    |> DateTime.from_unix!(:millisecond)
    |> floor_to_millisecond()
  end

  defp floor_to_millisecond(%DateTime{microsecond: {microsecond, _precision}} = datetime) do
    %{datetime | microsecond: {div(microsecond, 1_000) * 1_000, 6}}
  end
end
