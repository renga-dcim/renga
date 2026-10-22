defmodule RengaWeb.DesignSystemTest do
  @moduledoc """
  Keeps markup on the design system in `docs/design-system.md`, using the
  rules in `RengaUI.DesignGuard`. Screens written before the tokens are
  listed in `@legacy` with the number of violations they still carry; the
  count may only go down, and a file leaves the list once it reaches zero.
  """
  use ExUnit.Case, async: true

  import RengaUI.DesignGuard, only: [violations_in: 1]

  @legacy %{}

  # Deliberate exceptions, with the reason each one is not a token.
  @allowed %{
    # Each accent swatch shows its own color, not the one currently applied.
    "lib/renga_web/live/appearance_live.ex" => 5,
    # The native <dialog> scrim must darken the page in both themes.
    "lib/renga_web/components/layouts.ex" => 1,
    # An authenticator app's QR code needs dark modules on white to scan in
    # either theme.
    "lib/renga_web/live/user_live/settings.ex" => 1
  }

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
    counts = RengaUI.DesignGuard.scan(source_files())

    for {file, found} <- counts, found != [] do
      limit = Map.get(@legacy, file) || Map.get(@allowed, file, 0)

      assert length(found) <= limit, """
      #{file} has #{length(found)} design-system violations (allowed: #{limit}).
      Use the token names from docs/design-system.md instead:

      #{RengaUI.DesignGuard.format(found)}
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

  # The shared components in ui/ are held to the same rules.
  defp source_files do
    Enum.flat_map(["lib/renga_web", "ui/lib"], &Path.wildcard("#{&1}/**/*.{ex,heex}"))
  end
end
