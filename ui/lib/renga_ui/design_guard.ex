defmodule RengaUI.DesignGuard do
  @moduledoc """
  Finds markup that bypasses the design system in `docs/design-system.md`.

  Screens style themselves only through token names (bg-surface,
  text-fg-muted, ...) so accent, theme, and density switch at runtime. A raw
  Tailwind palette color, a hex color, or a former daisyUI name bypasses that
  and silently breaks in another accent or in dark mode. Each app runs this
  over its own templates in a test, with any deliberate exceptions it allows.
  """

  @palette ~w(slate gray zinc neutral stone red orange amber yellow lime green emerald
              teal cyan sky blue indigo violet purple fuchsia pink rose)
  @utilities ~w(bg text border ring divide outline fill stroke from via to decoration
                placeholder caret accent shadow)
  @daisy ~w(base-100 base-200 base-300 base-content primary-content primary
            secondary-content secondary neutral-content neutral accent-content
            info-content success-content success warning-content warning
            error-content error)
  @daisy_components ~w(alert badge btn link)

  @rules [
    {"raw Tailwind palette color",
     ~r/(?<![\w-])(?:[\w-]+:)*(?:#{Enum.join(@utilities, "|")})(?:-[trblxyse]{1,2})?-(?:(?:#{Enum.join(@palette, "|")})-\d{2,3}|black|white)(?:\/(?:\d{1,3}|\[[^\]]+\]))?(?![\w-])/},
    {"former daisyUI color name",
     ~r/(?<![\w-])(?:[\w-]+:)*(?:#{Enum.join(@utilities, "|")})-(?:#{Enum.join(@daisy, "|")})(?![\w-])/},
    {"former daisyUI component color",
     ~r/(?<![\w-])(?:[\w-]+:)*(?:#{Enum.join(@daisy_components, "|")})-(?:primary|secondary|accent|neutral|info|success|warning|error)(?![\w-])/},
    {"hex color",
     ~r/\#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})(?![0-9a-fA-F])/},
    {"text size outside the type scale", ~r/(?<![\w-])text-\[(?!1[01]px\])[^\]]+\]/},
    {"radius outside the radius scale",
     ~r/(?<![\w-])rounded(?:-[trblse]{1,2})?-(?:[2-4]xl|\[[^\]]+\])(?![\w-])/}
  ]

  @typedoc "A violation: the line number, the rule it breaks, and the matched text."
  @type violation :: {pos_integer(), String.t(), String.t()}

  @doc "Returns the violations in each file, keyed by path."
  @spec scan([Path.t()]) :: %{Path.t() => [violation()]}
  def scan(files), do: Map.new(files, &{&1, &1 |> File.read!() |> violations_in()})

  @doc "Returns the violations in a piece of markup."
  @spec violations_in(String.t()) :: [violation()]
  def violations_in(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line} ->
      for {rule, regex} <- @rules, [match] <- Regex.scan(regex, text), do: {line, rule, match}
    end)
  end

  @doc "Formats violations as one indented line each, for a test failure."
  @spec format([violation()]) :: String.t()
  def format(violations) do
    Enum.map_join(violations, "\n", fn {line, rule, match} ->
      "  line #{line}: #{rule} `#{match}`"
    end)
  end
end
