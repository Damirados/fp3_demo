defmodule Fp3Demo.DisplayView do
  @moduledoc """
  Emerge viewport rendered directly to the FP3 display through DRM/KMS.
  """

  use Emerge
  use Solve.Lookup

  alias Fp3Demo.UI.App

  @impl Viewport
  def mount(opts) do
    defaults = [
      backend: :drm,
      rendering_api: :opengl,
      drm_card: "/dev/dri/card0",
      width: 1080,
      height: 2160,
      hw_cursor: false,
      input_log: false,
      render_log: false,
      renderer_stats_log: true
    ]

    {:ok, Keyword.merge(defaults, opts)}
  end

  @impl Viewport
  def render do
    column(
      [
        width(fill()),
        height(fill()),
        padding(64),
        spacing(24),
        Background.color(color(:white)),
        Font.color(color(:black))
      ],
      [
        el(
          [
            padding(4),
            Font.size(64),
            Animation.animate(
              [[Transform.move_x(0)], [Transform.move_x(100)], [Transform.move_x(0)]],
              2000,
              :linear,
              :loop
            )
          ],
          text("Emerge on Fairphone 3")
        ),
        el([padding(4), Font.size(58)], text("Powered by Nerves")),
        battery_info(),
        scroll_rows()
      ]
    )
  end

  def battery_info do
    battery = solve(App, :battery)

    items = 
      Enum.filter(battery, fn {key, _} -> key in [:capacity, :status, :current_now] end)
      |> Enum.map(fn {key, value} ->
        el([align_bottom()], text("#{key}: #{value}"))
      end)

    row(
      [Font.size(24), spacing(10)],
      [el([Font.size(50), Font.bold()], text("Battery: ")) | items]

    )
  end

  def scroll_rows do
    column(
      [height(fill())],
      [
        el([padding(4), Font.size(48)], text("Buncha rows to have something to scroll")),
        column(
          [
            spacing(10),
            Font.size(40),
            scrollbar_y(),
            height(fill()),
            width(fill()),
            Font.color(color(:white))
          ],
          Enum.map(1..100, fn row -> item(row) end)
        )
      ]
    )
  end

  def item(row) do
    el(
      [
        width(fill()),
        padding(20),
        Background.color(row_color(row)),
        Border.rounded(8),
        Border.shadow(offset: {8, 8}, blur: 12, color: color_rgba(15, 23, 42, 0.75))
      ],
      text("Row #{row}")
    )
  end

  def row_color(n) do
    case rem(n, 6) do
      0 -> color(:slate, 600)
      1 -> color(:stone, 600)
      2 -> color(:emerald, 600)
      3 -> color(:indigo, 600)
      4 -> color(:mist, 600)
      5 -> color(:amber, 600)
    end
  end

  @impl Solve.Lookup
  def handle_solve_updated(_updated, state) do
    {:ok, Viewport.rerender(state)}
  end
end
