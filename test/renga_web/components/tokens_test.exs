defmodule RengaWeb.TokensTest do
  use ExUnit.Case, async: true

  test "primary button text meets WCAG AA in every explicit and system theme palette" do
    css = File.read!("assets/css/tokens.css")

    pairs =
      Regex.scan(~r/--rg-accent: (#[0-9a-f]{6});\s*--rg-accent-fg: (#[0-9a-f]{6});/, css)

    assert length(pairs) == 15

    for [_, background, foreground] <- pairs do
      [dark, light] = Enum.sort([luminance(background), luminance(foreground)])
      ratio = (light + 0.05) / (dark + 0.05)
      assert ratio >= 4.5, "#{foreground} on #{background} has contrast #{ratio}:1"
    end
  end

  defp luminance("#" <> hex) do
    channels =
      for <<channel::binary-size(2) <- hex>> do
        value = String.to_integer(channel, 16) / 255
        if value <= 0.04045, do: value / 12.92, else: ((value + 0.055) / 1.055) ** 2.4
      end

    [red, green, blue] = channels
    0.2126 * red + 0.7152 * green + 0.0722 * blue
  end
end
