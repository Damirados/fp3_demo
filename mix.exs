defmodule Fp3Demo.MixProject do
  use Mix.Project

  @app :fp3_demo
  @version "0.1.0"
  @all_targets [:fp3]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.20",
      archives: [nerves_bootstrap: "~> 1.17"],
      listeners: listeners(Mix.target(), Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Fp3Demo.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.5.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.12"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:nerves_system_fp3,
       path: "../nerves_system_fp3", runtime: false, targets: :fp3, nerves: [compile: true]},

      # Emerge DRM/GPU renderer. These sibling paths keep the application,
      # Elixir frame contract, and Rust frame contract on the same development revision.
      {:emerge, path: "../../emerge-headless"},
      {:video_interop, path: "../../video_interop", override: true},
      {:rustler, "~> 0.38.0", runtime: false},

      # Qualcomm bring-up: each of these owns one slice of it.
      {:ex_rmtfs, github: "mlainez/ex_rmtfs", targets: :fp3},
      {:ex_tqftpserv, github: "mlainez/ex_tqftpserv", targets: :fp3},
      {:ex_hexagonfs, github: "mlainez/ex_hexagonfs", targets: :fp3},
      {:ex_hexagonrpcd, github: "mlainez/ex_hexagonrpcd", targets: :fp3},
      {:ex_remoteproc, github: "mlainez/ex_remoteproc", targets: :fp3},

      # Cellular data.
      {:fp3_modem, github: "mlainez/fp3_modem", targets: :fp3}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://nerves-pack.hexdocs.pm/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  # Uncomment the following line if using Phoenix > 1.8.
  # defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []
end
