defmodule Fp3Demo.DisplayView do
  @moduledoc """
  Emerge viewport rendered directly to the FP3 display through DRM/KMS.
  """

  use Emerge

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
        column(
          [
            padding(10),
            Font.size(40),
            scrollbar_y(),
            height(fill()),
            width(fill()),
            Font.color(color(:white)),
            Background.color(color_rgba(0, 0, 0, 0)),
            Border.shadow(offset: {20, 20}, blur: 24, color: color_rgba(15, 23, 42, 0.75))
          ],
          [
            el([padding(4), Font.size(48)], text("Buncha rows to have something to scroll"))
            | Enum.map(1..100, fn row -> item(text("Row #{row}")) end)
          ]
        )
      ]
    )
  end

  def item(content) do
    el(
      [
        width(fill()),
        padding(20),
        Background.color(color(:slate, 600)),
        Border.rounded(8),
        Border.shadow(offset: {12, 12}, blur: 18, color: color_rgba(15, 23, 42, 0.75))
      ],
      content
    )
  end
end
