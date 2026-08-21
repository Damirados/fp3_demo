defmodule Fp3DemoTest do
  use ExUnit.Case
  doctest Fp3Demo

  test "greets the world" do
    assert Fp3Demo.hello() == :world
  end

  test "display viewport uses DRM defaults and accepts overrides" do
    assert {:ok, opts} = Fp3Demo.DisplayView.mount(width: 720, render_log: true)
    assert opts[:backend] == :drm
    assert opts[:rendering_api] == :opengl
    assert opts[:drm_card] == "/dev/dri/card0"
    assert opts[:width] == 720
    assert opts[:height] == 2160
    assert opts[:render_log]
  end
end
