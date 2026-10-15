defmodule RengaWeb.DesignSystemTest do
  @moduledoc """
  Keeps markup on the design system in `docs/design-system.md`.

  Screens style themselves only through token names (bg-surface,
  text-fg-muted, ...) so accent, theme, and density switch at runtime. A raw
  Tailwind palette color, a hex color, or a former daisyUI name bypasses that
  and silently breaks in another accent or in dark mode, so this test rejects
  them. Screens written before the tokens are listed in `@legacy` with the
  number of violations they still carry; the count may only go down, and a
  file leaves the list once it reaches zero.
  """
  use ExUnit.Case, async: true

  @legacy %{
    "lib/renga_web/live/catalog_live.ex" => 125,
    "lib/renga_web/live/vlan_group_live.ex" => 48
  }

  # Deliberate exceptions, with the reason each one is not a token.
  @allowed %{
    # Each accent swatch shows its own color, not the one currently applied.
    "lib/renga_web/live/appearance_live.ex" => 5,
    # The native <dialog> scrim must darken the page in both themes.
    "lib/renga_web/components/layouts.ex" => 1
  }

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

  test "recognizes every forbidden design-system category" do
    for class <- [
          "bg-red-500",
          "dark:border-t-red-500/30",
          "btn-primary",
          "text-base-content/60",
          "bg-[#fff]",
          "bg-[#11223344]",
          "text-[2rem]",
          "rounded-t-2xl",
          "rounded-4xl",
          "dark:rounded-t-4xl",
          "rounded-[40px]"
        ] do
      assert violations_in(~s(<div class="#{class}"></div>)) != [],
             "expected #{class} to violate the design system"
    end
  end

  test "accepts token classes and the documented arbitrary type sizes" do
    markup = """
    <div class="bg-surface border-t-edge text-fg rounded-xl text-[10px]"></div>
    <span class="bg-accent-tint text-[11px] shadow-lg"></span>
    """

    assert violations_in(markup) == []
  end

  test "markup uses design tokens instead of raw colors and off-scale values" do
    counts = Map.new(source_files(), &{&1, violations(&1)})

    for {file, found} <- counts, found != [] do
      limit = Map.get(@legacy, file) || Map.get(@allowed, file, 0)

      assert length(found) <= limit, """
      #{file} has #{length(found)} design-system violations (allowed: #{limit}).
      Use the token names from docs/design-system.md instead:

      #{Enum.map_join(found, "\n", fn {line, rule, match} -> "  line #{line}: #{rule} `#{match}`" end)}
      """
    end

    for {file, limit} <- Map.merge(@legacy, @allowed) do
      found = length(Map.get(counts, file, []))

      assert found == limit, """
      #{file} now has #{found} design-system violations; lower its entry in
      #{Path.relative_to_cwd(__ENV__.file)} to #{found} (and drop it at 0).
      """
    end
  end

  defp source_files do
    Path.wildcard("lib/renga_web/**/*.{ex,heex}")
  end

  defp violations(file) do
    file
    |> File.read!()
    |> violations_in()
  end

  defp violations_in(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line} ->
      for {rule, regex} <- @rules, [match] <- Regex.scan(regex, text), do: {line, rule, match}
    end)
  end
end
