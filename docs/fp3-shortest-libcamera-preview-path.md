# Shortest Libcamera-to-Emerge Camera Path for Fairphone 3/3+

**Status:** proposed minimum implementation path

**Date:** 2026-08-20

**Goal:** display a live FP3/FP3+ camera preview through libcamera and Emerge with the fewest new components, following the proven application shape in `../camera/`.
**Non-goal:** this document does not implement the MSM8953 VFE40 hardware ISP. See [`fp3-msm8953-vfe40-hardware-isp.md`](fp3-msm8953-vfe40-hardware-isp.md) for that longer-term work.

## Executive decision

The shortest useful route is:

```text
FP3/FP3+ Bayer sensor
  -> mainline MSM8953 CAMSS RDI
  -> libcamera Simple pipeline
  -> libcamera Software ISP, preferably EGL/GLES accelerated
  -> linear XRGB8888 DMA-BUF
  -> MembraneLibcamera.Source
  -> canonical leased %VideoInterop.Frame{}
  -> Membrane.VideoInterop.Sink
  -> EmergeSkia.VideoTarget
  -> Emerge DRM/OpenGL
  -> /dev/dri/card0 and the phone display
```

This deliberately copies only the narrow capture/transport/rendering spine from `../camera/`:

```text
MembraneLibcamera.Source
  -> Membrane.VideoInterop.Sink
  -> EmergeSkia.VideoTarget
```

It does **not** initially copy the Raspberry Pi application's Solve state model, detection streams, autofocus UI, Vulkan support, display profiles, extensive diagnostics, runtime restart machinery, or PiSP-specific configuration.

The key FP3 difference is the processed pixel format:

- Raspberry Pi `../camera/` receives hardware-PiSP **NV12**.
- MSM8953 mainline currently captures Bayer through RDI, and libcamera's Simple Software ISP emits 32-bit RGB formats.
- The FP3 preview should therefore request **XRGB8888**, not NV12.

Modern libcamera's CPU and EGL debayers both support `XRGB8888`. `MembraneLibcamera.Source` and Emerge's OpenGL video consumer already support strict linear `XRGB8888` DMA-BUFs. This avoids adding a color-conversion element or moving image bytes through the BEAM.

---

## 1. Why this is the shortest path

There are three possible open camera strategies on FP3:

1. Continue the custom V4L2/GStreamer/FFmpeg software pipeline.
2. Implement VFE40 hardware ISP support first.
3. Use libcamera's Simple pipeline and Software ISP, then connect its processed DMA-BUFs to Emerge.

Option 3 has the smallest dependency graph and reuses the most existing code.

### 1.1 What libcamera already provides

With a sufficiently recent libcamera build, the Simple pipeline provides:

- discovery of media-controller sensor pipelines;
- sensor acquisition and mode selection;
- request and buffer scheduling;
- exposure and analogue-gain control;
- Simple IPA AGC and AWB;
- black-level processing;
- Software ISP demosaic;
- optional CCM and adjustment algorithms;
- CPU Software ISP fallback;
- EGL/GLES GPU debayer;
- packed CSI-2 RAW10 and RAW12 support; and
- processed XRGB8888 DMA-BUF output.

### 1.2 What the sibling application already provides

The local projects used by `../camera/` already solve the application boundary:

- `../membrane_libcamera/` owns libcamera from a Rustler NIF and emits demand-driven canonical frames;
- `../../video_interop/` defines formats, DMA-BUF descriptors, synchronization, and leases;
- `../../membrane_video_interop/` transfers canonical frames from Membrane to a consumer safely;
- `../../emerge-headless/` can import XRGB8888 DMA-BUFs and render them as an Emerge video element; and
- this project already starts Emerge on the FP3 display using DRM/OpenGL.

The first implementation therefore does not need a new camera NIF, custom Membrane sink, raw-frame schema, EGL importer, or fd-lifetime protocol.

---

## 2. Exact minimum architecture

### 2.1 Capture and processing

```text
camera sensor
  -> CSIPHY
  -> CSID
  -> ISPIF
  -> msm_vfe*_rdi*
  -> packed RAW10 DMA-BUF
  -> libcamera Simple pipeline
  -> Simple IPA statistics/controls
  -> DebayerEGL or DebayerCpu
  -> XRGB8888 DMA-BUF
```

CAMSS RDI remains the kernel capture route. No VFE40 Bayer-processing changes are required for this plan.

### 2.2 Elixir and rendering

```text
%MembraneLibcamera.Source{
  output: :dmabuf,
  pixel_format: :XRGB8888
}
  -> %Membrane.VideoInterop.Sink{consumer: video_target}
  -> EmergeSkia.VideoTarget
  -> video(..., video_target)
  -> Emerge DRM/OpenGL renderer
```

The Membrane buffer payload remains empty. The canonical frame is carried under:

```elixir
buffer.metadata.video_interop
```

The `%VideoInterop.Frame{}` owns a lease covering the native libcamera request and its borrowed DMA-BUF fd. Emerge duplicates the borrowed fd during transfer and retires the lease only after GPU use. The BEAM never copies the image.

### 2.3 Format contract

The initial immutable stream contract should be:

| Property | Initial value |
|---|---|
| Processed format | `:XRGB8888` / DRM FourCC `XR24` |
| Modifier | explicit linear `0` |
| Planes | one |
| Objects | one |
| Alpha | opaque |
| Primaries | Rec.709 |
| Transfer | Rec.709 |
| Matrix/encoding | RGB / none |
| Range | full |
| Interlace | progressive |
| Chroma location | unspecified, because this is RGB |
| Acquire synchronization | implicit for first proof; sync-file after qualification |

`MembraneLibcamera.Source` deliberately rejects XRGB8888 unless `color_space: :rec709` is requested. It also rejects non-linear XRGB8888 modifiers. Emerge accepts `XR24` as a prime video target format.

---

## 3. System work required first

The application cannot use this route reliably with the current stock Buildroot libcamera package unchanged.

### 3.1 Replace Buildroot's old libcamera

The Nerves Buildroot package currently pins:

```make
LIBCAMERA_VERSION = v0.5.1
```

The modern local tree is:

```text
../libcamera/
commit: 06c385619acb10bbfb33f52f3abeb8f8c095f42b
version: v0.7.1+rpt20260609
remote: https://github.com/raspberrypi/libcamera
```

That modern tree contains the EGL/GLES Software ISP implementation, packed RAW10/RAW12 shaders, and the interfaces expected by the current `libcamera-rs`/`MembraneLibcamera` development code.

#### Use `../libcamera/` as the implementation tree

All FP3 libcamera work in this plan must be implemented and reviewed in the existing local checkout:

```text
../libcamera/
```

This includes the Simple-pipeline fixes, sensor helpers, static sensor properties, tuning YAML, Meson installation lists, and tests. Do not maintain those changes as opaque Buildroot patches or edit a copy under `output/build/`. Keeping the changes in the real libcamera repository makes them testable on the host and suitable for submission upstream.

During development, the custom Buildroot package should support a local source override in `../nerves_system_fp3/local.mk`:

```make
LIBCAMERA_FP3_OVERRIDE_SRCDIR = $(realpath $(NERVES_DEFCONFIG_DIR)/../libcamera)
```

The exact variable follows the eventual custom package name. Verify in the Buildroot log that the override is active; an unnoticed fallback to the remote tarball would make target results meaningless.

Use two source modes deliberately:

1. **Development firmware:** build from the clean or intentionally modified `../libcamera/` checkout through `LIBCAMERA_FP3_OVERRIDE_SRCDIR`.
2. **Reproducible firmware/CI:** push the validated libcamera commits, pin `LIBCAMERA_FP3_VERSION` to the exact resulting SHA, and disable the override.

Record both the libcamera SHA and `git status --short` in target qualification logs. Never publish an artifact whose package SHA describes different source from the local override used to build it.

Do not modify the generated dependency under `deps/nerves_system_br/...` as the durable solution. Add a custom package to `../nerves_system_fp3/`, following the package pattern already used by `../nerves_system_rpi5/package/rpi-libcamera-imx585/`.

A suitable package name is:

```text
../nerves_system_fp3/packages/libcamera-fp3/
  Config.in
  libcamera-fp3.mk
```

Then disable Buildroot's stock `BR2_PACKAGE_LIBCAMERA` and enable the custom package. Both packages install the same libraries and must never be enabled together.

### 3.2 Minimum Meson configuration

The custom package should build only the pieces required by this path:

```make
LIBCAMERA_FP3_CONF_OPTS = \
  -Dauto_features=disabled \
  -Dandroid=disabled \
  -Dcam=enabled \
  -Ddocumentation=disabled \
  -Dgstreamer=disabled \
  -Dipas=simple \
  -Dlc-compliance=disabled \
  -Dpipelines=simple \
  -Dpycamera=disabled \
  -Dqcam=disabled \
  -Dsoftisp-gpu=enabled \
  -Dtest=false \
  -Dtracing=disabled \
  -Dv4l2=disabled \
  -Dwerror=false
```

The critical options are:

```text
-Dpipelines=simple
-Dipas=simple
-Dsoftisp-gpu=enabled
```

Buildroot globally passes `-Dauto_features=disabled`. Without an explicit `-Dsoftisp-gpu=enabled`, the presence of Mesa EGL/GLES is not enough to turn on GPU processing.

The `cam` CLI is not required by the final application, but enabling it is useful for isolating libcamera before introducing Membrane and Emerge. It adds `libevent` as a dependency. It can be disabled after bring-up if image size matters.

### 3.3 Package dependencies

The custom package needs the usual libcamera host generators and target libraries plus Mesa ordering. Conceptually:

```make
LIBCAMERA_FP3_DEPENDENCIES = \
  host-openssl \
  host-pkgconf \
  host-python-jinja2 \
  host-python-ply \
  host-python-pyyaml \
  gnutls \
  libdrm \
  libevent \
  libyaml \
  mesa3d
```

The FP3 system already enables the important Mesa pieces:

```text
BR2_PACKAGE_MESA3D_GALLIUM_DRIVER_FREEDRENO=y
BR2_PACKAGE_MESA3D_OPENGL_ES=y
BR2_PACKAGE_MESA3D_OPENGL_EGL=y
BR2_PACKAGE_MESA3D_GBM=y
```

It also enables libdrm/Freedreno in the current display work.

### 3.4 IPA stripping and signing

Copy the existing Buildroot libcamera pattern that strips open-source IPA shared objects before Meson signs them. Buildroot may strip installed libraries later; signing unstripped content and then stripping it invalidates the signature.

The custom package needs a post-build hook equivalent to:

```make
find $(@D)/build/src/ipa -type f -name 'ipa_*.so' -print0 \
  | xargs --no-run-if-empty -0 $(STRIPCMD)
```

and then lets Meson install/sign the Simple IPA.

A firmware is not ready if the library is present but `ipa_simple.so` cannot load.

### 3.5 Required runtime nodes

Before testing libcamera, verify that the target has:

```text
/dev/media*
/dev/video*
/dev/v4l-subdev*
/dev/dri/card0
/dev/dri/renderD128        expected, but verify actual numbering
/dev/dma_heap/linux,cma    expected from CONFIG_DMABUF_HEAPS_CMA
```

The kernel configuration already contains:

```text
CONFIG_DMA_SHARED_BUFFER=y
CONFIG_DMABUF_HEAPS=y
CONFIG_DMABUF_HEAPS_CMA=y
```

The actual dma-heap and DRM node names remain target facts and must be checked after boot.

---

## 4. FP3/FP3+ libcamera sensor configuration plan

### 4.1 Initial behavior without FP3 tuning

The modern Simple IPA searches for per-sensor tuning under:

```text
src/ipa/simple/data/<sensor>.yaml
```

The inspected `../libcamera/` tree does not currently contain IMX363, S5K4H7YX, S5KGM1SP, or S5K3P9SP files. It falls back to `uncalibrated.yaml`, which enables:

- black level;
- AWB;
- adjustment; and
- AGC.

The fallback deliberately leaves CCM disabled.

The four sensors also lack `CameraSensorHelper` implementations. Simple IPA treats this as a warning rather than a fatal error. The fallback is poor for automatic exposure, however: it treats the raw V4L2 gain code as if it were an absolute gain multiplier. Unity is code `0` on three drivers and code `32` on S5K4H7YX, so metadata and AGC behavior cannot be trusted without helpers.

Consequences for an unconfigured first preview:

- camera enumeration and streaming can still work;
- a fixed exposure/gain test can prove the image and DMA-BUF path;
- automatic exposure and gain may converge incorrectly;
- colors will not be calibrated;
- CCM-based color accuracy will be poor or absent; and
- this is sufficient only for a moving-image proof.

Do not block initial enumeration on full tuning. Do add validated gain helpers before judging AGC, sensitivity, low-light behavior, or exposure metadata.

### 4.2 Researched FP3/FP3+ camera matrix

The exact kernel used by this system is available in `../linux-msm8953/` at commit `ec152ea739315950f8b83123875e76d3b11b2f28`. Its GPL sensor drivers and BSD-licensed runtime slot overlays are the best open technical source because they are also the code that creates the media graph libcamera will consume.

| Phone/slot | Sensor | Public unit cell | Kernel-exposed standard-Bayer modes relevant here | Native order | Module/topology facts |
|---|---|---:|---|---|---|
| FP3 rear | Sony IMX363, 12 MP | 1.4 µm | 4032x3024 and 2016x1512; also cropped 1920x1080 high-frame-rate modes | RGGB | rear-facing, rotation 270°, four CSI-2 lanes on CSIPHY0; AK7374 VCM; sensor may be strapped at I²C `0x10` or `0x1a` |
| FP3 front | Samsung S5K4H7YX/ISOCELL 4H7, 8 MP | 1.12 µm | 3264x2448, 1440x1080, 816x612, and 752x564 | GRBG | front-facing, rotation 270°, four lanes on CSIPHY2; fixed focus |
| FP3+ rear | Samsung S5KGM1SP/ISOCELL GM1, 48 MP native | 0.8 µm | 4000x3000 Tetrapixel output and 2000x1500 further-binned modes | GRBG as exported by this driver | rear-facing, rotation 270°, four lanes on CSIPHY0; DW9800W VCM |
| FP3+ front | Samsung S5K3P9SP/ISOCELL 3P9, 16 MP | 1.0 µm | 4608x3456 and 2304x1728 | GRBG as exported by this driver | front-facing, rotation 270°, four lanes on CSIPHY2; fixed focus |

The unit-cell values map to `CameraSensorProperties::unitCellSize` in nanometres:

```text
imx363:   { 1400, 1400 }
s5k4h7yx: { 1120, 1120 }
s5kgm1sp: {  800,  800 }
s5k3p9sp: { 1000, 1000 }
```

Evidence quality differs:

- Samsung publicly documents 4H7 as 8 MP/1.12 µm, GM1 as 48 MP/0.8 µm with four-pixel Tetrapixel 12 MP behavior, and 3P9 as 16 MP/1.0 µm with Tetracell.
- Fairphone's public material confirms the FP3 IMX363 and the FP3+ 48 MP/16 MP module upgrade. A complete public Sony IMX363 register datasheet was not found; the 1.4 µm unit cell is consistently reported in technical sources but should be labelled accordingly in a commit message.
- Resolutions, Bayer codes, clocks, CSI lanes, orientation, actuator links, and control ranges must come from the running GPL kernel driver rather than retail specification sites.

The modules are user-replaceable. A phone may contain any supported rear/front generation mix, so libcamera must select by the sensor model reported by the media graph, not by a global `FP3` versus `FP3+` setting.

### 4.3 Open-source source hierarchy

Use sources in this order:

1. **Runtime authority:** the exact GPL/BSD source in `../linux-msm8953/` and its matching [online commit](https://github.com/mlainez/linux-msm8953/tree/ec152ea739315950f8b83123875e76d3b11b2f28). It defines controls, mode timing, Bayer order, test-pattern indices, crop geometry, orientation, and module topology.
2. **Fairphone primary sources:** Fairphone's [FP3 GPL downloads](https://code.fairphone.com/projects/fairphone-3/gpl.html), [build instructions](https://code.fairphone.com/projects/fairphone-3/build-instructions.html), [FP3 life-cycle assessment](https://www.fairphone.com/wp-content/uploads/2023/08/Fairphone_3_LCA_final_noannex.pdf), and [FP3/FP3+ camera FAQ](https://support.fairphone.com/hc/en-us/articles/360047776791-Fairphone-3-Frequently-Asked-Questions-FAQ). These establish device/module identity and provide downstream source for comparison.
3. **Sensor-vendor primary sources:** Samsung's [4H7 product page](https://semiconductor.samsung.com/image-sensor/mobile-image-sensor/isocell-slim-4h7/), [GM1 announcement](https://semiconductor.samsung.com/us/news-events/news/introducing-two-new-0-point-8-micrometer-isocell-image-sensors/), and [3P9 announcement](https://news.samsung.com/us/samsung-makes-image-sensor-integration-easier-new-16mp-isocell-slim-3p9-plug-play-solution/). Use these for public physical characteristics, not undocumented register assumptions.
4. **libcamera authority:** the code and documentation in `../libcamera/`, especially `Documentation/sensor_driver_requirements.rst`, `src/ipa/libipa/camera_sensor_helper.cpp`, `src/libcamera/sensor/camera_sensor_properties.cpp`, and `src/ipa/simple/`.
5. **Controlled measurements:** dark frames, flat fields, ColorChecker captures, integrating-sphere or stable-light gain sweeps, and frame-sequenced control-delay tests made on actual FP3 and FP3+ modules.

Map each libcamera datum to its proper authority:

| Libcamera datum | Primary implementation source |
|---|---|
| sensor model string | running media entity and exact kernel driver |
| modes, crop, RAW depth, Bayer order | kernel driver plus target `enum_mbus_code`, `enum_frame_size`, and Selection API |
| pixel rate, line duration, exposure limits | live V4L2 controls; cross-check mode tables and link frequencies |
| orientation/rotation and camera location | active runtime slot overlay |
| analogue gain conversion | controlled raw gain sweep; kernel range is only a hint |
| black pedestal | controlled dark frames for each mode/gain range |
| control delays | frame-sequenced step-response measurement |
| unit-cell size | sensor-vendor public specifications, with confidence documented |
| CCM | independent ColorChecker calibration from linear RAW |
| lens shading | independent uniform flat-field calibration, once Simple supports it |
| focus device/range | active overlay, lens V4L2 controls, and measured endpoints |

The public [FP3 proprietary-file manifest](https://github.com/WeAreFairphone/android_device_fairphone_FP3/blob/lineage-16.0/proprietary-files.txt) names `imx363_chromatix.xml`, `s5k4h7yx_chromatix.xml`, module EEPROM parsers, and Qualcomm camera libraries. Android device history also identifies GM1/3P9 support and proprietary S5K3P9SP remosaic. Those names establish that vendor calibration existed; they do not make its binary coefficients redistributable or technically suitable for Simple IPA YAML.

Do not copy or translate proprietary Chromatix blobs into the open tuning files. Generate redistributable tuning from controlled calibration. The GPL kernel drivers may be used normally under their licences, even though their comments explain that register tables were reverse-engineered from vendor firmware.

No ready-to-use open libcamera helper, `CameraSensorProperties` entry, or Simple IPA tuning file was found online for any of these four exact model names. The credible implementation path is therefore the exact GPL kernel data plus measurements on the actual modules—not importing an unrelated phone's sensor tuning.

### 4.4 Add `CameraSensorHelper` implementations in `../libcamera/`

Implement and register four helpers in:

```text
../libcamera/src/ipa/libipa/camera_sensor_helper.cpp
```

The kernel control ranges strongly suggest these initial gain models:

| Sensor | V4L2 code range/default | Candidate real-gain equation | Candidate `AnalogueGainLinear` |
|---|---|---|---|
| IMX363 | `0..480`, default `0` | `512 / (512 - code)`; 480 gives 16x | `{ 0, 512, -1, 512 }` |
| S5K4H7YX | `32..512`, default `32` | `code / 32`; 32 is 1x, 512 is 16x | `{ 1, 0, 0, 32 }` |
| S5KGM1SP | `0..978`, default `0` | candidate `1024 / (1024 - code)` | `{ 0, 1024, -1, 1024 }` if measured |
| S5K3P9SP | `0..978`, default `0` | candidate `1024 / (1024 - code)` | `{ 0, 1024, -1, 1024 }` if measured |

The IMX363 model matches the existing IMX214/IMX258 helper family and its 0-to-480 range. The Samsung formulas are plausible from their unity and maximum codes, but no public GM1/3P9 register manual was found. Treat every row as a hypothesis until a raw gain sweep confirms it; do not merge a helper solely because the endpoints look familiar.

Validate each model by holding illumination and exposure constant, capturing unsaturated RAW frames across at least 12 gain codes, subtracting a measured black pedestal, and fitting mean signal relative to unity. Check both directions:

```text
gain(code) -> measured signal multiplier
gainCode(requested gain) -> expected kernel code
```

Include endpoint, unity, 2x, 4x, 8x, and near-maximum tests. Add or port the libcamera gain round-trip test described by [CameraSensorHelper gain-model test work](https://patchwork.libcamera.org/patch/23030/) so every valid representative code satisfies the expected quantization behavior.

Measure black level separately for every sensor and binned/full mode using capped, short-exposure, unity-gain RAW frames. The existing FP3 utility uses 64 in 10-bit space, corresponding to `4096` in libcamera's 16-bit helper scale, but that one working value is not proof for all four sensors. Leave `blackLevel_` unset until measured; then record the method and sample count in the commit.

### 4.5 Add static sensor properties

Add four entries to:

```text
../libcamera/src/libcamera/sensor/camera_sensor_properties.cpp
```

Populate:

- the unit-cell sizes above;
- test-pattern mappings; and
- measured sensor-control delays.

All four current kernel drivers expose the same V4L2 test-pattern menu indices:

```text
0 Disabled
1 Solid Colour
2 Colour Bars
3 Colour Bars With Fade to Grey
4 PN9
```

Map those to libcamera's Off, SolidColor, ColorBars, ColorBarsFadeToGray, and Pn9 controls. Confirm each actual pattern before publishing; a menu label alone does not prove that its color ordering meets libcamera's expected pattern.

The kernel firmware nodes already report `rotation = 270`, with orientation `1` for rear and `0` for front. Do not duplicate those module placement values in the sensor database.

Do not guess delays. The Simple pipeline delays exposure and gain controls based on `CameraSensorProperties`. Measure a step response with frame sequence numbers: change one control, compute raw-frame medians, and identify the first frame that reflects it. Test exposure and gain independently at 15 and 30 fps for each driver. Leave `.sensorDelays = {}` temporarily if unmeasured; libcamera will warn and use its documented unverified defaults rather than presenting guesses as facts.

### 4.6 Add per-sensor Simple IPA YAML

Create in `../libcamera/`:

```text
src/ipa/simple/data/imx363.yaml
src/ipa/simple/data/s5k4h7yx.yaml
src/ipa/simple/data/s5kgm1sp.yaml
src/ipa/simple/data/s5k3p9sp.yaml
```

and add all four files to:

```text
src/ipa/simple/data/meson.build
```

Start each file as a sensor-named copy of `uncalibrated.yaml`. This removes ambiguous fallback selection while preserving known behavior. Then add only measured data.

The current Simple IPA YAML can usefully carry:

- a fixed `BlackLevel.blackLevel` in 16-bit scale, after dark-frame validation; and
- `Ccm.ccms`, with matrices indexed by measured color temperature.

A calibrated shape is:

```yaml
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
      blackLevel: 4096 # example only; replace with this sensor's measurement
  - Awb:
  - Ccm:
      ccms:
        - ct: 2850
          ccm: [ ...nine measured coefficients... ]
        - ct: 6500
          ccm: [ ...nine measured coefficients... ]
  - Adjust:
  - Agc:
...
```

Do not commit the example coefficients or assume black level 4096 globally. Capture raw ColorChecker data under at least a warm source near 2850 K, a neutral source around 4000–5000 K, and a daylight/D65 source. Solve matrices from linear, black-subtracted, white-balanced sensor values; validate on separate captures and constrain neutral preservation.

The current Simple AWB and AGC implementations have little or no per-sensor YAML parameterization, and Simple Software ISP does not yet expose a complete lens-shading/denoise/sharpen tuning stack. Do not invent unsupported YAML keys. Extend the algorithms separately if measured quality requires those features.

### 4.7 Tetrapixel and remosaic caution

GM1 and 3P9 are four-cell color-filter sensors:

- GM1's normal 4000x3000 output combines its 48 MP/0.8 µm array to a 12 MP result. This is the appropriate standard-Bayer quality mode for the first FP3+ rear work.
- 3P9's 2304x1728 mode is the safe first front-camera mode. Public Samsung material describes Tetracell, while Android device history explicitly refers to proprietary S5K3P9SP remosaic support.

Do not assume that a 4608x3456 S5K3P9SP frame is ordinary GRBG merely because the V4L2 driver advertises that media-bus code. Capture a color chart and high-frequency target, inspect the 2x2/4x4 color periodicity, and establish whether the sensor register mode performs remosaic internally. If it exposes a quad-Bayer mosaic, exclude full resolution from Simple DebayerEGL until an open remosaic stage exists.

### 4.8 Calibration and configuration completion gates

A sensor is considered configured only when:

- [ ] the model name exactly matches the kernel media entity and IPA lookup;
- [ ] gain-code conversion is measured and unit-tested;
- [ ] black pedestal is measured for the preview mode;
- [ ] unit-cell and test-pattern properties are present;
- [ ] control delays are measured or explicitly left unknown;
- [ ] the named YAML is installed in the target IPA data directory;
- [ ] fixed exposure/gain metadata matches raw measurements;
- [ ] AGC converges without large oscillation;
- [ ] AWB no longer uses pedestal-biased ratios;
- [ ] calibrated CCMs improve held-out ColorChecker error;
- [ ] Bayer order is validated for every enabled flip and mode; and
- [ ] Tetrapixel full-resolution modes are either proven standard Bayer or rejected.

Keep per-sensor configuration work separate from the initial DRM/display proof, but keep it in the same `../libcamera/` source tree so the final target package has one auditable camera stack.

### 4.9 Module EEPROM and per-unit calibration research

Upstream FP3 device-tree work identifies a read-only BL24S64/24C64-compatible EEPROM at I²C `0x50` beside at least the IMX363 rear module. The Android proprietary-file manifest names an `ofilm_imx363_bl24s64` EEPROM parser. Together these are credible evidence of module-specific identification/calibration data, but neither source publishes a reusable byte layout.

This is not required for first preview. A later clean-room investigation should:

1. expose the EEPROM read-only through nvmem without disturbing camera power sequencing;
2. dump multiple legally owned modules and record full hashes;
3. identify checksums and fields from controlled differences and physical calibration, not copied parser output;
4. determine whether data represents AWB ratios, lens shading, AF endpoints, serial/module identity, or defects;
5. add a documented open parser only when the format is independently established; and
6. keep generic sensor YAML as fallback when no valid module calibration is available.

The [upstream CCI/EEPROM device-tree patch](https://www.spinics.net/lists/devicetree/msg862074.html) is a useful electrical/topology source. Its actuator description differs from the exact runtime slot overlay used here, reinforcing that the active `../linux-msm8953/` media graph—not a web page—is authoritative for the fitted module.

---

## 5. Application dependencies

Add only the direct camera/Membrane dependencies used by the narrow graph:

```elixir
# mix.exs
{:membrane_core, "~> 1.2"},
{:membrane_video_interop, path: "../../membrane_video_interop"},
{:membrane_libcamera, path: "../membrane_libcamera"}
```

The project already has:

```elixir
{:emerge, path: "../../emerge-headless"},
{:rustler, "~> 0.38.0", runtime: false}
```

Emerge and the Membrane components declare their own versioned VideoInterop dependencies; the
application does not duplicate that transitive dependency.

Align the Rustler override with the sibling camera project if dependency resolution requires it:

```elixir
{:rustler, "~> 0.38.0", override: true}
```

`membrane_libcamera` pulls in `membrane_video_interop` and `video_interop`; their compatible
version constraints keep the Elixir and Rust frame contracts aligned.

### 5.1 Native build requirements

`MembraneLibcamera`'s Rust NIF links against the libcamera library and headers from the Nerves staging sysroot. Therefore the custom libcamera package must use:

```make
LIBCAMERA_FP3_INSTALL_STAGING = YES
```

The Nerves build environment must expose working target `pkg-config` entries for libcamera. A firmware can contain runtime libraries while the NIF build still fails if staging headers or `.pc` files are missing.

For the first implementation, let Rustler cross-compile the NIF through the normal Nerves dependency build. Before shipping, verify that the NIF copied into the release is a little-endian AArch64 ELF and links to the target libcamera ABI. If host/target artifact contamination appears, port only the small NIF-staging/ELF-validation step from `../camera/mix.exs`; do not copy its unrelated detection and Vulkan release stages.

---

## 6. Minimum application code

Only two new logical pieces are required:

1. an Emerge viewport that creates and displays an `EmergeSkia.VideoTarget`; and
2. a Membrane pipeline connecting `MembraneLibcamera.Source` to `Membrane.VideoInterop.Sink`.

A small owner process may be added later for graceful restarts. For the first proof, the viewport can start one pipeline after its renderer is ready and the entire appliance can be rebooted after a terminal camera failure.

### 6.1 Minimal Membrane pipeline

Representative shape:

```elixir
defmodule Fp3Demo.CameraPipeline do
  use Membrane.Pipeline

  import Membrane.ChildrenSpec

  alias Membrane.VideoInterop.Sink, as: VideoInteropSink

  @impl true
  def handle_init(_ctx, opts) do
    target = Keyword.fetch!(opts, :video_target)
    camera = Keyword.fetch!(opts, :camera)
    sensor_mode = Keyword.fetch!(opts, :sensor_mode)
    width = Keyword.fetch!(opts, :width)
    height = Keyword.fetch!(opts, :height)

    source = %MembraneLibcamera.Source{
      camera: camera,
      sensor_mode: sensor_mode,
      width: width,
      height: height,
      framerate: {15, 1},
      output: :dmabuf,
      pixel_format: :XRGB8888,
      acquire_sync: :implicit,
      color_space: :rec709,
      chroma_location: :unspecified,
      buffer_count: 6,
      max_in_flight: 2,
      minimum_queued_requests: 2,
      diagnostics_interval_ms: 2_000,
      strict: true
    }

    spec =
      child(:camera, source)
      |> child(:display, %VideoInteropSink{
        consumer: target,
        on_error: :stop,
        completion_policy: :standalone,
        notify_to: self()
      })

    {[spec: spec], %{}}
  end
end
```

This intentionally omits:

- analysis stream;
- a custom observer;
- runtime controls;
- autofocus;
- camera restart;
- frame copying;
- custom sinks; and
- NV12 conversion.

The first framerate is 15 fps to reduce bring-up pressure. Raise it only after the processing and display timings are known.

### 6.2 Minimal viewport state

The current `Fp3Demo.DisplayView` already starts Emerge's DRM/OpenGL renderer. Extend its user state with:

```elixir
%{
  video_target: nil,
  pipeline_supervisor: nil,
  pipeline: nil
}
```

After Emerge exposes the renderer, create one exact-size target:

```elixir
{:ok, target} =
  EmergeSkia.video_target(renderer,
    id: "fp3-camera-preview",
    width: output_width,
    height: output_height,
    mode: :prime
  )
```

Start `Fp3Demo.CameraPipeline` with that target and retain both returned PIDs. The target must be stored in viewport state and included in the render tree:

```elixir
video(
  [width(fill()), height(fill()), image_fit(:contain)],
  target
)
```

The target dimensions must exactly match the processed libcamera stream dimensions. Emerge handles fitting those dimensions into the 1080x2160 phone viewport.

A loading element can be rendered while `video_target` is `nil`.

### 6.3 Start ordering

Use this order:

1. Start Emerge on `/dev/dri/card0`.
2. Wait until its renderer exists.
3. Create the renderer-owned video target.
4. Store the target and rerender the scene so it contains `video(...)`.
5. Start the Membrane pipeline.
6. Let Membrane demand start libcamera capture.

Starting capture before the target appears in the render tree is not a correctness violation—Emerge releases frames for inactive targets—but it can hide the first-frame result and complicate logs.

### 6.4 Supervision for the proof

Keep the first supervision policy simple:

```text
Fp3Demo.DisplayView owns one CameraPipeline instance.
No hot camera restart is attempted.
A terminal ownership or native-session failure requires appliance reboot.
```

This avoids pretending that an abrupt pipeline failure is safely reusable. `MembraneLibcamera`, `VideoInterop`, and Emerge contain fail-closed ownership guards, but a skipped orderly drain can still quarantine same-VM camera reuse.

After the first preview is stable, port the lifecycle pattern from `../camera/`:

- a separate `StreamRuntime`;
- target attachment before pipeline start;
- source/sink/native drain barriers;
- exact pipeline PID and generation correlation;
- cold-restart latch for ownership-unknown failures; and
- verified renderer presentation readiness.

Those are production hardening steps, not prerequisites for the first image.

---

## 7. Sensor and size selection

Do not hardcode one sensor index or geometry for every phone. The camera modules are replaceable, and FP3 and FP3+ use different sensors.

Known preview modes from the exact `../linux-msm8953/` drivers are:

| Sensor | Largest kernel-exposed mode | First preview mode | Advertised Bayer order |
|---|---:|---:|---|
| IMX363 | 4032x3024 | 2016x1512 | RGGB |
| S5KGM1SP | 4000x3000 Tetrapixel output | 2000x1500 | GRBG |
| S5K4H7YX | 3264x2448 | 1440x1080 | GRBG |
| S5K3P9SP | 4608x3456, remosaic status to validate | 2304x1728 | GRBG |

The kernel also exposes high-frame-rate/cropped modes for some sensors. They are not part of the shortest preview path and must not be enabled until their actual cadence, Bayer phase, and GPU cost are qualified.

Use discovery as the authority:

```elixir
{:ok, cameras} = MembraneLibcamera.list_cameras()

Enum.map(cameras, fn camera ->
  {camera.id, camera.sensor_modes}
end)
```

For the first GPU Software ISP test:

1. select one discovered rear camera by stable ID;
2. select its discovered binned RAW10 mode;
3. initially set XRGB output dimensions equal to that mode; and
4. request 15 fps.

Using equal input/output dimensions avoids making the first test depend on the current `DebayerEGL` scale/crop behavior. The implementation currently creates output-sized textures but uses an input-sized `glViewport()`; downscale and center-crop behavior needs target validation.

After native-size preview works, test a smaller output such as 1080x810 or another even 4:3 size to reduce memory bandwidth.

---

## 8. Why the first output must be XRGB8888

Modern `DebayerEGL` advertises:

```text
XRGB8888
ARGB8888
XBGR8888
ABGR8888
```

for supported standard Bayer RAW8, unpacked RAW10, packed RAW10, and packed RAW12 inputs. It does not produce NV12.

`DebayerCpu` also supports XRGB8888, so the same application format works if GPU processing is disabled or unavailable.

Requesting NV12 would either fail negotiation or select a path that does not represent the Simple Software ISP result. Adding a separate RGB-to-NV12 stage would increase work and is unnecessary for direct display.

XRGB8888 also simplifies first rendering:

- one object;
- one plane;
- no chroma siting;
- no YUV conversion shader in Emerge;
- full-range RGB color contract; and
- direct support in the current Emerge video consumer.

The cost is memory bandwidth: a 2000x1500 XRGB frame is approximately 12 MB. This is why the binned mode, low initial frame rate, and bounded six-buffer pool matter.

---

## 9. GPU Software ISP behavior on Freedreno

The modern Software ISP uses EGL/GLES for debayer and related image processing. On the FP3 this should execute on Mesa Freedreno for Adreno 506.

There are two separate GPU contexts:

1. libcamera's Software ISP context writes the processed XRGB DMA-BUF; and
2. Emerge's DRM/OpenGL context imports and samples that DMA-BUF into the display composition.

This is expected. The image does not need to pass through Elixir memory.

### 9.1 Input import uncertainty

The GPU ISP attempts to import the raw Bayer DMA-BUF, including an `R8`-style representation for packed/raw data where supported. Direct import on Adreno 506 must be tested.

If direct raw import is unavailable, libcamera has a CPU-upload fallback for the input texture. That still permits GPU demosaic and XRGB DMA-BUF output, but it is not a fully zero-copy sensor-to-GPU path and may cost CPU time.

### 9.2 Output import requirements

`MembraneLibcamera` requires XRGB8888 output to report:

- one object;
- one plane referencing object zero;
- pitch at least `width * 4`;
- sufficient real allocation size; and
- explicit linear modifier `0`.

Emerge then duplicates the borrowed object fd and imports it with EGL DMA-BUF attributes. Any modifier, pitch, or allocation-size mismatch fails closed instead of guessing.

### 9.3 Synchronization progression

For the first proof, use:

```elixir
acquire_sync: :implicit
```

This has fewer moving pieces and matches normal EGL/DMA-BUF implicit fencing. After the preview works, switch to:

```elixir
acquire_sync: :sync_file
```

and validate that `MembraneLibcamera` can export a read acquire fence from the completed output buffer and that Emerge imports/waits it correctly. Production should prefer explicit sync, but explicit-fence export should not block the first image.

Do not silently fall back from requested sync-file mode to implicit mode. Build separate, deliberate qualification steps.

---

## 10. Smallest validation sequence

Each stage should pass before adding the next layer.

### Stage A: existing kernel RAW capture

Confirm the current raw path independently of libcamera:

```text
media-ctl -p
v4l2-ctl --list-devices
fp3-cam-setup rear binned
```

Capture a known good RAW frame with the existing utilities. This proves sensor power, CSI, media links, VFE RDI, and packed format.

### Stage B: modern libcamera enumeration

On the target:

```text
lc-cam --help
lc-cam --list
```

or use the installed executable name if the custom package installs it as `cam`.

Expected evidence:

- the Simple pipeline matches the CAMSS media device;
- each available sensor appears as a camera;
- binned RAW10 modes are listed;
- Simple IPA loads in-process with a valid signature;
- missing sensor helper/tuning appears only as warnings; and
- no media graph is claimed twice by another camera utility.

### Stage C: libcamera XRGB capture without Emerge

Use `cam`/`lc-cam` to request a finite number of XRGB8888 frames at a binned size. Save or checksum them. Consult `lc-cam --help` for the exact CLI syntax of the pinned revision rather than embedding an older command line into scripts.

Verify:

- negotiated FourCC is `XR24`;
- frame stride is at least width times four;
- sequence numbers advance;
- exposure settles;
- image geometry and Bayer phase are recognizable; and
- the process exits and releases the camera cleanly.

### Stage D: Membrane discovery

In IEx:

```elixir
{:ok, cameras} = MembraneLibcamera.list_cameras()
```

Inspect IDs and sensor modes. Do not start Emerge camera capture yet.

### Stage E: Membrane-to-Emerge preview

Start the exact two-element graph:

```text
MembraneLibcamera.Source -> Membrane.VideoInterop.Sink
```

with the Emerge target as consumer.

Expected evidence:

- `%VideoInterop.Format{}` reports XR24, linear modifier, RGB/full Rec.709;
- source diagnostics show request completions and delivered frames;
- Emerge reports video submissions and imports;
- the preview appears in the Emerge `video` element; and
- the existing text/UI can render over or around the preview.

### Stage F: explicit synchronization

Change only:

```elixir
acquire_sync: :implicit
```

to:

```elixir
acquire_sync: :sync_file
```

Require successful fence export/import, unchanged image output, and no stalls or timeouts.

### Stage G: soak

Run for at least several thousand frames and compare:

- `/proc/<beam-pid>/fd` count;
- active libcamera leases;
- camera request availability;
- completion versus delivery rate;
- Emerge pending replacement count;
- retired GPU resources;
- RSS/CMA usage; and
- start/stop behavior.

No steadily increasing fd, lease, request, or imported-image count is acceptable.

---

## 11. Minimal acceptance criteria

The first milestone is complete when all of the following are true:

- [ ] Modern libcamera builds from the recorded `../libcamera/` SHA and working-tree state.
- [ ] Release/CI firmware pins the exact validated libcamera commit rather than relying on a local override.
- [ ] Build summary reports Simple pipeline, Simple IPA, and GPU SoftISP enabled.
- [ ] `ipa_simple.so` loads successfully on target.
- [ ] At least one rear sensor is discovered through CAMSS.
- [ ] A discovered binned RAW10 mode streams through libcamera.
- [ ] Processed output negotiates as linear XRGB8888/XR24.
- [ ] `MembraneLibcamera.Source` emits canonical DMA-BUF frames.
- [ ] `Membrane.VideoInterop.Sink` opens the Emerge target consumer.
- [ ] Emerge imports and displays frames on `/dev/dri/card0` using OpenGL.
- [ ] No image bytes are copied through a BEAM binary.
- [ ] Repeated frames do not leak fds or leases.
- [ ] Camera shutdown either completes cleanly or explicitly requires a reboot; the application never guesses that an unknown session is reusable.

Image color does not need to be calibrated for this milestone.

---

## 12. Explicitly deferred work

To preserve the shortest path, defer all of the following:

- VFE40 Bayer hardware ISP programming;
- CPP;
- NV12 output;
- Venus encoding;
- all-camera simultaneous streaming;
- full-resolution dual-VFE modes;
- remosaic;
- lens-shading calibration;
- per-sensor CCM tuning;
- denoise and sharpening tuning;
- autofocus algorithms;
- secondary analysis streams;
- face/foreground detection;
- Vulkan;
- automatic OpenGL/Vulkan fallback;
- hot pipeline restart;
- complex Solve state and controls UI;
- RTP/HTTP streaming; and
- direct DRM plane scanout of the camera buffer.

These can be layered on only after the direct preview spine works.

---

## 13. Immediate rollback paths

### 13.1 CPU Software ISP rollback

If `DebayerEGL` cannot operate correctly on Freedreno, rebuild the same modern libcamera package with:

```text
-Dsoftisp-gpu=disabled
```

Keep the application output as XRGB8888. `DebayerCpu` also supports XRGB8888, so no Membrane or Emerge code change should be necessary. Performance may be low, but this distinguishes GPU-ISP failures from camera/application failures.

### 13.2 Existing raw utilities

Retain `fp3-camera-utils` and the current V4L2 raw path. They remain the authority for checking whether a regression is below libcamera.

### 13.3 Existing display-only view

Keep the current `Fp3Demo.DisplayView` text scene available behind a simple build/config switch. This distinguishes Emerge/DRM startup failures from video import failures.

There should be no automatic in-stream fallback that hides a failed contract. Select each rollback intentionally at boot/build time and record it in logs.

---

## 14. What to port from `../camera/` after the proof

Once the shortest graph works, copy behavior rather than copying the entire application blindly.

### Port next

- `Camera.LibcameraPipeline`'s use of `Membrane.VideoInterop.Sink`;
- exact stream-format notifications;
- bounded capture diagnostics;
- renderer-owned video target creation before capture;
- orderly source/sink/native drain barriers;
- exact pipeline/session correlation;
- cold-restart policy for ownership-unknown failures; and
- first-frame presentation proof through Emerge renderer statistics.

### Do not port unless needed

- Raspberry Pi platform module loading;
- PiSP sensor role/topology options;
- NV12 chroma-site qualification;
- V3DV allocation workarounds;
- Vulkan device selection;
- HDMI display profiles;
- CEF168 tuning;
- analysis stream/detection stack;
- autofocus controls UI; and
- Raspberry Pi cadence/performance probes.

### FP3-specific substitutions

| `../camera/` concept | FP3 shortest-path replacement |
|---|---|
| PiSP hardware ISP | libcamera Simple Software ISP |
| NV12 | XRGB8888/XR24 |
| V3D/V3DV | Freedreno a5xx OpenGL |
| `/dev/dri/card1` | `/dev/dri/card0` |
| 2560x1440 preview | discovered FP3 binned 4:3 mode initially |
| explicit Vulkan sync | implicit GL first, sync-file GL second |
| IMX585 tuning | uncalibrated Simple fallback first |

---

## 15. Known blockers and likely first failures

### 15.1 Old libcamera package

**Symptom:** missing GPU SoftISP option/features or NIF compile/API mismatch.

**Fix:** replace v0.5.1 with the pinned modern custom package before application integration.

### 15.2 Simple IPA not built

**Symptom:** camera enumerates but IPA fails to load, or no automatic processing path starts.

**Fix:** explicitly configure both `-Dpipelines=simple` and `-Dipas=simple`; preserve strip-before-sign ordering.

### 15.3 EGL/GLES not detected at build time

**Symptom:** build summary reports GPU SoftISP disabled or Meson errors because it was required.

**Fix:** add `mesa3d` package dependency and verify target staging contains `egl.pc`, `glesv2.pc`, and `EGL/egl.h`.

### 15.4 Raw DMA-BUF import failure

**Symptom:** `DebayerEGL` rejects or logs failure importing the Bayer buffer.

**Fix:** confirm whether libcamera's CPU texture-upload fallback activates. If not usable, select CPU SoftISP as the explicit first rollback.

### 15.5 Output-size/viewport mismatch

**Symptom:** blank, cropped, or incorrectly scaled XRGB output.

**Fix:** make initial output dimensions equal the selected binned sensor mode; defer downscaling until native-size output is correct.

### 15.6 Non-linear or unspecified XRGB modifier

**Symptom:** `MembraneLibcamera.Source` rejects `non_linear_xrgb8888_modifier` or invalid modifier.

**Fix:** inspect the actual libcamera allocator/export. Do not forge modifier zero. Ensure the Software ISP allocates linear output buffers.

### 15.7 Color-space adjustment

**Symptom:** strict source setup fails because libcamera adjusts the requested color contract.

**Fix:** inspect the negotiated libcamera color space. XRGB must be Rec.709 primaries/transfer, RGB encoding, full range for the current strict source contract. Do not label an unknown color space as Rec.709.

### 15.8 Explicit fence export failure

**Symptom:** sync-file mode terminates while implicit mode works.

**Fix:** retain implicit mode for the first proof, then investigate DMA-BUF reservation/fence publication by DebayerEGL. Do not silently downgrade a sync-file request.

### 15.9 Sensor helper and tuning warnings

**Symptom:** warning about missing helper/configuration and poor colors.

**Fix:** accept for the first image; add per-sensor helpers and tuning in a separate milestone.

### 15.10 Camera cannot reopen after a crash

**Symptom:** same-VM restart is quarantined or fails after abrupt pipeline termination.

**Fix:** reboot for the initial demo. Before enabling automatic restarts, port the complete drain/guardian/cold-restart policy from `../camera/`.

---

## 16. Recommended implementation order

The shortest safe order is:

1. **Use `../libcamera/` as the source tree** and create a focused FP3 topic branch.
2. **Add the custom modern libcamera package** in `../nerves_system_fp3/`, with `LIBCAMERA_FP3_OVERRIDE_SRCDIR` for local development.
3. **Target CLI proof** of Simple IPA and fixed-exposure XRGB output using `uncalibrated.yaml`.
4. **Implement and measure per-sensor gain helpers** in `../libcamera/`; do not judge AGC before this.
5. **Add static properties and sensor-named baseline YAML** for all four sensors.
6. **Add Membrane dependencies** to this application.
7. **Cross-build and verify the MembraneLibcamera NIF** against target staging.
8. **Add one minimal `Fp3Demo.CameraPipeline`**.
9. **Extend `Fp3Demo.DisplayView` with one Emerge video target**.
10. **Run one binned rear mode at 15 fps with implicit sync**.
11. **Qualify sync-file mode**.
12. **Run fd/lease/request soak tests**.
13. **Measure black level/control delays and add independently calibrated CCMs** in `../libcamera/`.
14. **Validate the other three sensor/module combinations**, including S5K3P9SP remosaic status.
15. **Push and pin the exact validated libcamera commit** for reproducible firmware.
16. **Port production lifecycle hardening**.
17. **Only then evaluate hardware VFE40 as a backend replacement for Software ISP**.

This order keeps failures attributable to one boundary at a time.

---

## 17. Final proposed first configuration

The first target attempt should use values discovered from the booted phone, but the shape should be:

```elixir
%MembraneLibcamera.Source{
  camera: discovered_rear_camera,
  sensor_mode: discovered_binned_raw10_mode,
  width: discovered_binned_raw10_mode.width,
  height: discovered_binned_raw10_mode.height,
  framerate: {15, 1},
  output: :dmabuf,
  pixel_format: :XRGB8888,
  acquire_sync: :implicit,
  color_space: :rec709,
  chroma_location: :unspecified,
  buffer_count: 6,
  max_in_flight: 2,
  minimum_queued_requests: 2,
  diagnostics_interval_ms: 2_000,
  strict: true,
  controls: %{}
}
```

The matching Emerge target is:

```elixir
EmergeSkia.video_target(renderer,
  id: "fp3-camera-preview",
  width: discovered_binned_raw10_mode.width,
  height: discovered_binned_raw10_mode.height,
  mode: :prime
)
```

The render tree uses:

```elixir
video(
  [width(fill()), height(fill()), image_fit(:contain)],
  video_target
)
```

This is the smallest direct analogue of `../camera/` that matches the capabilities of mainline MSM8953 today.

---

## 18. Source references

### Local implementation references

- `../camera/README.md`
- `../camera/lib/camera/libcamera_pipeline.ex`
- `../camera/lib/camera/viewport.ex`
- `../camera/lib/camera/stream_runtime.ex`
- `../membrane_libcamera/README.md`
- `../membrane_libcamera/lib/membrane_libcamera/source.ex`
- `../../membrane_video_interop/README.md`
- `../../emerge-headless/guides/internals/video-interop-architecture.md`
- `../../emerge-headless/lib/emerge_skia/video_target_consumer.ex`

### Libcamera implementation references

- `../libcamera/` — required implementation tree, baseline `06c385619acb10bbfb33f52f3abeb8f8c095f42b`
- `../libcamera/Documentation/sensor_driver_requirements.rst`
- `../libcamera/src/libcamera/pipeline/simple/`
- `../libcamera/src/libcamera/software_isp/debayer_egl.cpp`
- `../libcamera/src/libcamera/software_isp/debayer_cpu.cpp`
- `../libcamera/src/libcamera/software_isp/meson.build`
- `../libcamera/src/libcamera/sensor/camera_sensor_properties.cpp`
- `../libcamera/src/ipa/libipa/camera_sensor_helper.cpp`
- `../libcamera/src/ipa/simple/`
- `../libcamera/src/ipa/simple/data/meson.build`
- `../libcamera/src/ipa/simple/data/uncalibrated.yaml`
- [libcamera Sensor Driver Requirements](https://docs.libcamera.org/master/sensor_driver_requirements.html)
- [CameraSensorHelper gain round-trip test](https://patchwork.libcamera.org/patch/23030/)
- [Proposed analogue-gain/black-level measurement tool](https://patchwork.libcamera.org/patch/27732/) — useful methodology, but its sample parser assumes unpacked 16-bit RAW; adapt it for CAMSS packed RAW10 or feed it output from the existing FP3 unpacker
- [Proposed Camera Sensor Helper guide](https://patchwork.libcamera.org/patch/27733/)

### Exact FP3 kernel references

Local source, all at `../linux-msm8953/` commit `ec152ea739315950f8b83123875e76d3b11b2f28`:

- `drivers/media/i2c/imx363.c`
- `drivers/media/i2c/s5k4h7yx.c`
- `drivers/media/i2c/s5kgm1sp.c`
- `drivers/media/i2c/s5k3p9sp.c`
- `drivers/misc/fp3_module_slot.c`
- `drivers/misc/fp3-slot-cam-rear-imx363-10.dtso`
- `drivers/misc/fp3-slot-cam-rear-imx363-1a.dtso`
- `drivers/misc/fp3-slot-cam-front-s5k4h7yx.dtso`
- `drivers/misc/fp3-slot-cam-rear-s5kgm1sp.dtso`
- `drivers/misc/fp3-slot-cam-front-s5k3p9sp.dtso`

Pinned online source:

- [linux-msm8953 exact tree](https://github.com/mlainez/linux-msm8953/tree/ec152ea739315950f8b83123875e76d3b11b2f28)
- [IMX363 driver](https://github.com/mlainez/linux-msm8953/blob/ec152ea739315950f8b83123875e76d3b11b2f28/drivers/media/i2c/imx363.c)
- [S5K4H7YX driver](https://github.com/mlainez/linux-msm8953/blob/ec152ea739315950f8b83123875e76d3b11b2f28/drivers/media/i2c/s5k4h7yx.c)
- [S5KGM1SP driver](https://github.com/mlainez/linux-msm8953/blob/ec152ea739315950f8b83123875e76d3b11b2f28/drivers/media/i2c/s5kgm1sp.c)
- [S5K3P9SP driver](https://github.com/mlainez/linux-msm8953/blob/ec152ea739315950f8b83123875e76d3b11b2f28/drivers/media/i2c/s5k3p9sp.c)
- [FP3 module-slot detector](https://github.com/mlainez/linux-msm8953/blob/ec152ea739315950f8b83123875e76d3b11b2f28/drivers/misc/fp3_module_slot.c)
- [IMX363 rear overlay at 0x10](https://github.com/mlainez/linux-msm8953/blob/ec152ea739315950f8b83123875e76d3b11b2f28/drivers/misc/fp3-slot-cam-rear-imx363-10.dtso)
- [IMX363 rear overlay at 0x1a](https://github.com/mlainez/linux-msm8953/blob/ec152ea739315950f8b83123875e76d3b11b2f28/drivers/misc/fp3-slot-cam-rear-imx363-1a.dtso)
- [S5K4H7YX front overlay](https://github.com/mlainez/linux-msm8953/blob/ec152ea739315950f8b83123875e76d3b11b2f28/drivers/misc/fp3-slot-cam-front-s5k4h7yx.dtso)
- [S5KGM1SP rear overlay](https://github.com/mlainez/linux-msm8953/blob/ec152ea739315950f8b83123875e76d3b11b2f28/drivers/misc/fp3-slot-cam-rear-s5kgm1sp.dtso)
- [S5K3P9SP front overlay](https://github.com/mlainez/linux-msm8953/blob/ec152ea739315950f8b83123875e76d3b11b2f28/drivers/misc/fp3-slot-cam-front-s5k3p9sp.dtso)

### Fairphone and sensor-vendor research sources

- [Fairphone FP3 GPL source downloads](https://code.fairphone.com/projects/fairphone-3/gpl.html)
- [Fairphone FP3 build instructions and public manifests](https://code.fairphone.com/projects/fairphone-3/build-instructions.html)
- [Fairphone 3 life-cycle assessment](https://www.fairphone.com/wp-content/uploads/2023/08/Fairphone_3_LCA_final_noannex.pdf)
- [Archived Fairphone 3 technical-specification document index](https://downloads.muxmaeuschenwild.de/FAIRPHONE/Fairphone%203)
- [Technical IMX363 pixel-pitch reference](https://stanford.edu/~wandell/data/papers/2022-Gordon-Conference-Wandell.pdf) — secondary evidence because no public Sony IMX363 datasheet was found
- [Fairphone 3/3+ camera FAQ](https://support.fairphone.com/hc/en-us/articles/360047776791-Fairphone-3-Frequently-Asked-Questions-FAQ)
- [Fairphone 3/3+ module identification](https://support.fairphone.com/hc/en-us/articles/360054177752-Fairphone-3-Identify-the-Modules)
- [Samsung ISOCELL 4H7 specifications](https://semiconductor.samsung.com/image-sensor/mobile-image-sensor/isocell-slim-4h7/)
- [Samsung ISOCELL GM1 announcement and Tetrapixel description](https://semiconductor.samsung.com/us/news-events/news/introducing-two-new-0-point-8-micrometer-isocell-image-sensors/)
- [Samsung ISOCELL 3P9 announcement](https://news.samsung.com/us/samsung-makes-image-sensor-integration-easier-new-16mp-isocell-slim-3p9-plug-play-solution/)
- [FP3 proprietary-file manifest](https://github.com/WeAreFairphone/android_device_fairphone_FP3/blob/lineage-16.0/proprietary-files.txt) — inventory/evidence only; not a tuning-data licence
- [S5K3P9SP remosaic device-history evidence](https://gitlab.e.foundation/e/devices/android_device_fairphone_FP3/-/commit/67a026b1) — establishes an Android remosaic dependency, not reusable implementation data
- [Upstream FP3 CCI and rear EEPROM patch](https://www.spinics.net/lists/devicetree/msg862074.html)

### FP3 system references

- `../nerves_system_fp3/nerves_defconfig`
- `../nerves_system_fp3/linux-6.19.defconfig`
- `../nerves_system_fp3/packages/fp3-camera-utils/`
- `../nerves_system_fp3/post-build.sh`

### Custom-package model

- `../nerves_system_rpi5/package/rpi-libcamera-imx585/Config.in`
- `../nerves_system_rpi5/package/rpi-libcamera-imx585/rpi-libcamera-imx585.mk`
