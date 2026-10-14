defmodule RengaWeb.Brand do
  @moduledoc """
  Renga's logo: the mark and the wordmark, drawn inline so they take the
  person's accent and theme like any other token-styled element.

  The mark is an R built from 1U rack slabs laid in running-bond brick
  (Renga, 煉瓦, is Japanese for brick). The wordmark uses that mark as its first
  letter and lays "enga" in the same courses, so the two always match. The
  geometry comes from the brand board; every value is in units of a 24-unit
  grid where one course is 3.6 tall with 1 unit of mortar. Scale the SVG as a
  whole and never re-space the bricks: the gaps are part of the mark.

  Both draw with `currentColor`. The mark takes `text-accent` by default; in
  the two-tone wordmark the R takes the accent and the letters take the
  surrounding text color.
  """
  use Phoenix.Component

  # Each brick is {x, y, width, height, corner radius}.
  @primary [
    {3.5, 1.0, 9.5, 3.6, 0.9},
    {14.0, 1.0, 5.0, 3.6, 0.9},
    {3.5, 5.6, 3.8, 3.6, 0.9},
    {15.7, 5.6, 4.8, 3.6, 0.9},
    {3.5, 10.2, 5.0, 3.6, 0.9},
    {9.5, 10.2, 9.5, 3.6, 0.9},
    {3.5, 14.8, 3.8, 3.6, 0.9},
    {12.1, 14.8, 4.6, 3.6, 0.9},
    {3.5, 19.4, 3.8, 3.6, 0.9},
    {15.9, 19.4, 4.6, 3.6, 0.9}
  ]

  @inverted [
    {1.0, 0.9, 7.03, 2.7, 0.5},
    {8.58, 0.9, 6.75, 2.7, 0.5},
    {15.88, 0.9, 7.12, 2.7, 0.5},
    {1.0, 4.15, 4.16, 2.7, 0.5},
    {17.73, 4.15, 5.27, 2.7, 0.5},
    {1.0, 7.4, 4.16, 2.7, 0.5},
    {9.07, 7.4, 5.12, 2.7, 0.5},
    {18.84, 7.4, 4.16, 2.7, 0.5},
    {1.0, 10.65, 4.16, 2.7, 0.5},
    {17.73, 10.65, 5.27, 2.7, 0.5},
    {1.0, 13.9, 4.16, 2.7, 0.5},
    {9.07, 13.9, 2.45, 2.7, 0.5},
    {16.03, 13.9, 6.97, 2.7, 0.5},
    {1.0, 17.15, 4.16, 2.7, 0.5},
    {9.07, 17.15, 5.26, 2.7, 0.5},
    {18.84, 17.15, 4.16, 2.7, 0.5},
    {1.0, 20.4, 7.03, 2.7, 0.5},
    {8.58, 20.4, 6.75, 2.7, 0.5},
    {15.88, 20.4, 7.12, 2.7, 0.5}
  ]

  @word_r [
    {0.0, 1.0, 9.5, 3.6, 0.9},
    {10.5, 1.0, 5.0, 3.6, 0.9},
    {0.0, 5.6, 3.8, 3.6, 0.9},
    {12.2, 5.6, 4.8, 3.6, 0.9},
    {0.0, 10.2, 5.0, 3.6, 0.9},
    {6.0, 10.2, 9.5, 3.6, 0.9},
    {0.0, 14.8, 3.8, 3.6, 0.9},
    {8.6, 14.8, 4.6, 3.6, 0.9},
    {0.0, 19.4, 3.8, 3.6, 0.9},
    {12.4, 19.4, 4.6, 3.6, 0.9}
  ]

  @enga [
    {27.6, 5.6, 8.6, 3.6, 0.9},
    {22.8, 10.2, 3.8, 3.6, 0.9},
    {27.6, 10.2, 13.4, 3.6, 0.9},
    {22.8, 14.8, 3.8, 3.6, 0.9},
    {27.6, 19.4, 8.6, 3.6, 0.9},
    {46.8, 5.6, 13.4, 3.6, 0.9},
    {46.8, 10.2, 3.8, 3.6, 0.9},
    {61.2, 10.2, 3.8, 3.6, 0.9},
    {46.8, 14.8, 3.8, 3.6, 0.9},
    {61.2, 14.8, 3.8, 3.6, 0.9},
    {46.8, 19.4, 3.8, 3.6, 0.9},
    {61.2, 19.4, 3.8, 3.6, 0.9},
    {75.6, 5.6, 13.4, 3.6, 0.9},
    {70.8, 10.2, 3.8, 3.6, 0.9},
    {85.2, 10.2, 3.8, 3.6, 0.9},
    {70.8, 14.8, 3.8, 3.6, 0.9},
    {85.2, 14.8, 3.8, 3.6, 0.9},
    {75.6, 19.4, 13.4, 3.6, 0.9},
    {85.2, 24.0, 3.8, 3.6, 0.9},
    {70.8, 28.6, 13.4, 3.6, 0.9},
    {94.8, 5.6, 13.4, 3.6, 0.9},
    {99.6, 10.2, 13.4, 3.6, 0.9},
    {94.8, 14.8, 3.8, 3.6, 0.9},
    {109.2, 14.8, 3.8, 3.6, 0.9},
    {99.6, 19.4, 13.4, 3.6, 0.9}
  ]

  @enga_caps [
    {22.8, 1.0, 3.8, 3.6, 0.9},
    {27.6, 1.0, 13.4, 3.6, 0.9},
    {22.8, 5.6, 3.8, 3.6, 0.9},
    {22.8, 10.2, 13.4, 3.6, 0.9},
    {22.8, 14.8, 3.8, 3.6, 0.9},
    {22.8, 19.4, 3.8, 3.6, 0.9},
    {27.6, 19.4, 13.4, 3.6, 0.9},
    {46.8, 1.0, 3.8, 3.6, 0.9},
    {61.2, 1.0, 3.8, 3.6, 0.9},
    {46.8, 5.6, 8.6, 3.6, 0.9},
    {61.2, 5.6, 3.8, 3.6, 0.9},
    {46.8, 10.2, 3.8, 3.6, 0.9},
    {56.4, 10.2, 8.6, 3.6, 0.9},
    {46.8, 14.8, 3.8, 3.6, 0.9},
    {61.2, 14.8, 3.8, 3.6, 0.9},
    {46.8, 19.4, 3.8, 3.6, 0.9},
    {61.2, 19.4, 3.8, 3.6, 0.9},
    {75.6, 1.0, 13.4, 3.6, 0.9},
    {70.8, 5.6, 3.8, 3.6, 0.9},
    {70.8, 10.2, 3.8, 3.6, 0.9},
    {80.4, 10.2, 8.6, 3.6, 0.9},
    {70.8, 14.8, 3.8, 3.6, 0.9},
    {85.2, 14.8, 3.8, 3.6, 0.9},
    {75.6, 19.4, 13.4, 3.6, 0.9},
    {99.6, 1.0, 8.6, 3.6, 0.9},
    {94.8, 5.6, 3.8, 3.6, 0.9},
    {109.2, 5.6, 3.8, 3.6, 0.9},
    {94.8, 10.2, 3.8, 3.6, 0.9},
    {99.6, 10.2, 13.4, 3.6, 0.9},
    {94.8, 14.8, 3.8, 3.6, 0.9},
    {109.2, 14.8, 3.8, 3.6, 0.9},
    {94.8, 19.4, 3.8, 3.6, 0.9},
    {109.2, 19.4, 3.8, 3.6, 0.9}
  ]

  @doc """
  Renders the mark.

  `:primary` is the bricks themselves, for use beside the name and anywhere
  20px or larger. `:inverted` leaves the R as a gap in a wall, for larger
  standalone uses such as the sign-in card; keep it at 24px or larger.
  """
  attr :variant, :atom, default: :primary, values: [:primary, :inverted]
  attr :class, :any, default: "size-6 text-accent"
  attr :rest, :global

  def mark(assigns) do
    assigns =
      assign(assigns, :bricks, if(assigns.variant == :inverted, do: @inverted, else: @primary))

    ~H"""
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" class={@class} {@rest}>
      <rect :for={{x, y, w, h, r} <- @bricks} x={x} y={y} width={w} height={h} rx={r} />
    </svg>
    """
  end

  @doc """
  Renders the wordmark: the mark as the R, then "enga".

  Lowercase is the default and reads as a name; `caps` sets "ENGA" at the R's
  full height for labels and other places that want a squarer block. Set the
  height with `class`; the width follows. `tone={:one}` draws the R in the
  text color too, for places that should carry no accent.
  """
  attr :caps, :boolean, default: false
  attr :tone, :atom, default: :two, values: [:one, :two]
  attr :class, :any, default: "h-6 w-auto text-fg"
  attr :rest, :global

  def wordmark(assigns) do
    assigns =
      assign(assigns,
        letters: if(assigns.caps, do: @enga_caps, else: @enga),
        # Lowercase leaves room below the baseline for the g's tail.
        view_box: if(assigns.caps, do: "0 0 113 24", else: "0 0 113 33.2"),
        word_r: @word_r
      )

    ~H"""
    <svg
      viewBox={@view_box}
      fill="currentColor"
      role="img"
      aria-label="Renga"
      class={@class}
      {@rest}
    >
      <g class={@tone == :two && "text-accent"}>
        <rect :for={{x, y, w, h, r} <- @word_r} x={x} y={y} width={w} height={h} rx={r} />
      </g>
      <rect :for={{x, y, w, h, r} <- @letters} x={x} y={y} width={w} height={h} rx={r} />
    </svg>
    """
  end
end
