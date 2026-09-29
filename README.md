# FP3 Demo

Nerves application for bringing up direct DRM/KMS rendering and the open camera
stack on the Fairphone 3 and 3+.

The application currently starts an Emerge viewport on `/dev/dri/card0` using
Mesa Freedreno's EGL/OpenGL path. Vulkan is intentionally disabled because the
Adreno 506/a5xx does not have a Mesa Turnip driver.

## Related development trees

This checkout expects these sibling repositories:

- `../nerves_system_fp3` — FP3 kernel, firmware, Mesa, and runtime packages;
- `../../emerge-headless` — Emerge DRM renderer despite the historical repo name; and
- `../libcamera` — active libcamera development tree for future camera preview.

Emerge resolves its VideoInterop dependency from Hex and crates.io.

## Build and test

Host checks:

```sh
mix format --check-formatted
mix test
```

FP3 firmware:

```sh
MIX_TARGET=fp3 mix deps.get
MIX_TARGET=fp3 mix firmware
```

A target build requires an SSH public key in `~/.ssh`. The user performing
hardware validation should verify `/dev/dri/card0`, the Freedreno render node,
and the expected Mesa libraries before judging the viewport.

Only flash the resulting full image to Android's `userdata` partition, as
documented by `../linux-msm8953/AGENTS.md`. Do not flash the phone's `boot`
partition.

## Camera plans

Camera preview is researched but not yet wired into the application:

- [`docs/fp3-shortest-libcamera-preview-path.md`](docs/fp3-shortest-libcamera-preview-path.md)
  defines the shortest CAMSS-to-libcamera-to-Emerge DMA-BUF path and the
  per-sensor configuration workflow.
- [`docs/fp3-msm8953-vfe40-hardware-isp.md`](docs/fp3-msm8953-vfe40-hardware-isp.md)
  documents a separate open VFE40 hardware-ISP implementation plan.

The first camera milestone keeps libcamera's GPU Software ISP as the reference
and fallback. VFE40 work remains a separate kernel and pipeline project.
