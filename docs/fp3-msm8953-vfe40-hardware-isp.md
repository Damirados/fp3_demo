# Fairphone 3 / MSM8953 VFE40 Hardware ISP Findings

**Research status:** 2026-08-20

**Scope:** Linux community and publicly available Qualcomm/Fairphone sources relevant to using the Fairphone 3/3+ hardware ISP instead of relying exclusively on RAW Bayer capture followed by software demosaic.
**Repository impact:** This document records research only. It does not implement or enable the hardware ISP.

## Executive summary

The Fairphone 3 camera subsystem contains a genuine and capable hardware image signal processor. The relevant block is Qualcomm **VFE40**, reported for MSM8953 as hardware version `0x10090000`. It is not limited to CSI capture or DMA: Qualcomm's downstream GPL kernel code and the stock camera modules show support for Bayer-domain processing, demosaic, white balance, color correction, tone processing, scaling, cropping, sharpening, and several kinds of image statistics.

The present upstream Linux CAMSS driver does not expose most of that functionality. For this VFE generation it primarily supports:

- RAW Bayer capture through an RDI path, which bypasses image processing; and
- a PIX path intended for packed-YUV input, with chroma conversion, scaling, and cropping.

That is why the current open FP3 pipeline captures Bayer through CAMSS RDI and performs demosaic and color processing in libcamera's Software ISP. The missing component is not the silicon. It is a clean mainline kernel API and driver implementation for configuring VFE40's Bayer-processing blocks and returning their statistics.

There has nevertheless been useful recent Linux-community progress:

1. Mainline CAMSS already manages the FP3's clocks, media topology, CSI receiver, VFE DMA engines, and buffer flow.
2. Linux now has an extensible generic V4L2 ISP-parameter framework suitable for a new VFE40 userspace API.
3. Qualcomm and Ideas on Board have proposed the first open Qualcomm hardware-ISP driver, for the newer Offline Processing Engine (OPE), together with libcamera integration work.
4. Older GPL VFE40 drivers publish a substantial register map, DMI/LUT handling, statistics handling, and ISP command implementation.

The OPE driver itself cannot be backported as an FP3 solution because MSM8953 does not contain OPE. It is, however, a valuable architectural model. A VFE40 implementation for FP3 is therefore a real engineering project, not a configuration toggle, but it is technically credible and no longer a blind reverse-engineering exercise.

The recommended first experiment is a separate kernel topic branch implementing a fixed, minimally tuned pipeline:

```text
RAW10 sensor
  -> CSIPHY
  -> CSID
  -> ISPIF PIX
  -> VFE40 demosaic/WB/CCM/RGB-to-YUV/scale
  -> NV12 DMA-BUF
```

This should be proven before adding a stable userspace ABI, automatic algorithms, or CPP post-processing.

---

## 1. Current open FP3 camera pipeline

The current project has working access to the FP3 and FP3+ camera sensors through Qualcomm CAMSS. The relevant sensors investigated in the local trees are:

- Sony IMX363
- Samsung S5K4H7YX
- Samsung S5KGM1SP
- Samsung S5K3P9SP

The useful open path today is conceptually:

```text
sensor RAW Bayer
  -> MIPI CSI-2
  -> CAMSS CSIPHY
  -> CAMSS CSID
  -> ISPIF
  -> VFE RDI
  -> Bayer DMA buffer in system memory
  -> libcamera Software ISP
  -> RGB output
```

### 1.1 What RDI means

RDI is the VFE's raw data interface. It is designed to write a CSI data stream to memory without passing it through the main VFE pixel-processing chain. This is useful for:

- RAW capture;
- debugging sensors and CSI links;
- implementing an ISP in CPU or GPU software; and
- preserving raw frames alongside a separately processed stream.

It does **not** imply that VFE40 lacks an ISP. It means the chosen route bypasses that ISP.

### 1.2 Why libcamera uses Software ISP

Mainline's VFE40/4.1 PIX support is oriented toward sensors or upstream blocks that already provide packed YUV. The FP3 sensors output Bayer RAW10/RAW12. Since the mainline PIX sink does not expose the required Bayer-to-YUV processing interface, the usable media route is RDI.

Libcamera's Simple pipeline then performs the missing operations in software. The newer local libcamera tree improves this significantly with an EGL/GLES GPU Software ISP, packed RAW10/RAW12 handling, DMA-BUF support, and algorithms for AGC, AWB, black level, CCM, gamma, and contrast. That remains a valuable fallback and reference pipeline, but it is not equivalent to using the dedicated VFE hardware in power use, memory traffic, or available ISP features.

---

## 2. MSM8953 camera hardware topology

Fairphone's downstream device tree describes a complete Qualcomm camera subsystem at `0x01b00000`, including:

- three CSIPHY instances;
- three CSID instances;
- ISPIF;
- two VFE40 instances;
- CPP;
- JPEG hardware;
- CCI camera-control interfaces;
- camera SMMU contexts; and
- the associated clocks, regulators, interrupts, VBIF regions, and bandwidth controls.

The important downstream nodes are:

| Block | Address | Downstream compatible | Purpose |
|---|---:|---|---|
| CAMSS root | `0x01b00000` | `qcom,msm-cam` | Camera subsystem resources |
| VFE0 | `0x01b10000` | `qcom,vfe40` | Live capture and image processing |
| VFE1 | `0x01b14000` | `qcom,vfe40` | Second VFE / split or concurrent use |
| CPP | `0x01b04000` | `qcom,cpp` | Firmware-driven YUV post-processing |
| JPEG | `0x01b1c000` | `qcom,jpeg` | JPEG encoding |

Both VFE instances are assigned nominal source rates in the downstream device tree and list a maximum rate of 465 MHz. Actual usable throughput depends on mode, line width, memory bandwidth, clock voting, and whether dual-VFE operation is required.

### 2.1 Live VFE versus offline OPE

It is important not to conflate two different Qualcomm ISP designs:

- **VFE40 PIX** is part of the live CAMSS capture pipeline. Pixels arrive from CSID/ISPIF and pass through the ISP before being written to memory.
- **OPE** is a newer offline engine. It reads an already memory-backed frame, processes it, and writes another frame to memory.

The FP3 has VFE40 and CPP. It does not have the newer OPE register block described by the proposed QCM2290/Agatti driver.

---

## 3. Evidence that VFE40 is a full ISP

### 3.1 Fairphone's GPL downstream kernel

Fairphone's downstream `msm_isp40.c` explicitly recognizes `VFE40_8953_VERSION`. Its error and violation handling names the following hardware units:

- CAMIF
- black correction
- rolloff
- demux
- demosaic
- white balance
- chroma/luma filtering
- color correction
- RGB LUT
- luma adaptation
- chroma enhancement
- chroma suppression and memory color enhancement
- skin enhancement
- encoder and view color transforms
- luma and chroma scaling
- adaptive spatial filtering
- luma and chroma cropping
- output realignment

The same driver exposes dedicated statistics channels for:

- BE: Bayer exposure statistics
- BG: Bayer grid statistics
- BF: Bayer focus statistics
- AWB statistics
- RS: row sum
- CS: column sum
- IHIST: intensity histogram
- BHIST: Bayer histogram

This is direct evidence from the GPL kernel driver that the hardware can perform much more than RDI capture.

### 3.2 Stock FP3 camera modules

The FP3 vendor image/manifest contains Qualcomm camera modules corresponding to the VFE40 ISP stages. Examples include modules for:

- `demosaic40`
- `mesh_rolloff40`
- `color_correct40`
- `gamma40`
- `abf40`
- `bpc40`
- `wb40`
- encoder/view scaling and cropping

The vendor image also contains per-sensor Chromatix files and proprietary libraries for the four FP3/FP3+ sensors. This proves that the stock Android camera stack uses the VFE40 processing pipeline and has sensor-specific tuning for it.

It does not make the proprietary tuning redistributable or immediately usable by libcamera. The files are evidence of the intended hardware path, not an acceptable source for copying tuning data into an open project.

### 3.3 Public GPL VFE40 implementation

An older Linux Foundation GPL VFE40 driver publishes a broad register map and command implementation. Among other things, it defines:

- demosaic and defect-correction regions;
- mesh rolloff DMI banks;
- linearization tables;
- white-balance registers;
- a 3x3 color-correction matrix plus offsets;
- RGB gamma LUT banks;
- luma adaptation;
- chroma conversion and suppression;
- scaler and crop registers;
- adaptive spatial filtering;
- Bayer statistics engines; and
- per-frame register-update interrupts.

The register addresses align strongly with the VFE4.1 definitions already used by mainline CAMSS. This is important: the old ISP implementation and current mainline DMA driver are visibly operating the same hardware family.

---

## 4. Mainline VFE40/4.1 support: what exists and what is absent

Mainline Linux supports MSM8953 CAMSS topology and the basic VFE4.1 data path. The relevant implementation is:

```text
drivers/media/platform/qcom/camss/camss-vfe-4-1.c
```

### 4.1 Existing reusable support

The current driver already handles substantial low-level work:

- CAMSS power and clock management;
- VFE reset and interrupt handling;
- CAMIF timing for the supported PIX path;
- RDI configuration;
- write-master allocation;
- ping/pong DMA buffer updates;
- output stride and plane configuration;
- media-controller entities and links;
- stream start/stop ordering;
- register-update synchronization;
- supported packed-YUV transformations;
- chroma upsampling/subsampling;
- encoder scaling; and
- cropping.

This foundation should be extended rather than replaced.

### 4.2 Matching register map

Representative register offsets found in the GPL VFE40 implementation and the mainline VFE4.1 family include:

| Function | Offset |
|---|---:|
| Module configuration | `0x018` |
| AXI/write-master area | `0x06c` onward |
| CAMIF command/configuration | around `0x2f4` |
| Register update | `0x378` |
| Mesh rolloff | `0x400` |
| Demux | `0x424` |
| Demosaic/ABF/BPC | `0x440` onward |
| White balance | `0x580` |
| Color correction | `0x5d0` |
| Chroma conversion | `0x640` |
| Encoder scaler | `0x75c` |
| Encoder crop | `0x854` |
| Statistics configuration | around `0x888` |
| DMI configuration/data | `0x910` onward |

Exact fields and revision-specific behavior still need validation on MSM8953, but the mapping is close enough to establish that mainline already owns and operates the same core.

### 4.3 Current PIX limitations

The current VFE4.1 PIX setup recognizes packed YUV input orders such as:

- YUYV
- YVYU
- UYVY
- VYUY

It enables a limited set of modules equivalent to:

```text
DEMUX | CHROMA_UPSAMPLE | SCALE_ENC | CROP_ENC
```

This supports YUV-to-YUV layout conversion, scale, and crop. It does not configure the Bayer chain needed for an FP3 RAW sensor:

- Bayer phase/pattern and raw demux;
- black level and linearization;
- rolloff;
- demosaic;
- Bayer denoise/defect correction;
- white balance;
- color correction;
- gamma/tone processing; or
- Bayer statistics.

### 4.4 Missing userspace API

Even if fixed register values were added to the kernel, a production camera pipeline would need to change settings every frame or every few frames. Examples include:

- WB gains from AWB;
- color matrix selection/interpolation;
- exposure-dependent black level and denoise;
- gamma/tone parameters;
- lens-shading tables;
- focus windows and thresholds; and
- crop/scale changes.

Mainline currently has no VFE40-specific metadata node or UAPI through which libcamera can provide those settings. Nor does it expose the hardware statistics buffers needed by AE, AWB, and AF.

This API gap is the main reason that enabling the complete ISP is more than adding a few register writes.

---

## 5. Relevant Linux-community progress

### 5.1 Upstream CAMSS

The community CAMSS driver has reached the point where FP3 can enumerate and capture through the standard media-controller and V4L2 APIs. That is foundational progress: sensor drivers, CSI routing, power sequencing, DMA, and buffer ownership no longer depend on Qualcomm's Android camera daemon.

For MSM8953, however, this work has largely stopped at RAW RDI capture and limited YUV PIX handling. The research found no existing mainline or active community series that implements VFE40 Bayer processing and statistics for MSM8953.

### 5.2 Open libcamera Software ISP

Ideas on Board, Linaro, Red Hat, and libcamera contributors developed Software ISP support partly because Qualcomm hardware ISP interfaces were not open. This is the pipeline currently applicable to FP3.

The GPU Software ISP under development is a meaningful improvement over CPU demosaic and should still be pursued as:

- the shortest route to an open usable camera;
- a fallback if the hardware path fails for a sensor/mode;
- a reference image pipeline for validating VFE output;
- a tuning and calibration environment; and
- a way to capture RGB when a hardware block only offers YUV output.

It should now be viewed as a complementary path, not proof that hardware ISP work is impossible.

### 5.3 Generic extensible V4L2 ISP parameters

Linux now provides generic structures and helper functions in:

```text
include/uapi/linux/media/v4l2-isp.h
drivers/media/v4l2-core/v4l2-isp.c
```

The design lets each hardware driver define its own metadata format while using an extensible, versioned buffer composed of individual ISP parameter blocks. This is preferable to freezing one monolithic C structure that mirrors all ISP registers forever.

A VFE40 driver could define block types such as:

```text
VFE40_PARAMS_BLACK_LEVEL
VFE40_PARAMS_DEMUX
VFE40_PARAMS_ROLLOFF
VFE40_PARAMS_DEMOSAIC
VFE40_PARAMS_BPC
VFE40_PARAMS_ABF
VFE40_PARAMS_WHITE_BALANCE
VFE40_PARAMS_COLOR_CORRECTION
VFE40_PARAMS_GAMMA
VFE40_PARAMS_CHROMA_CONVERSION
VFE40_PARAMS_SCALE_CROP
```

The kernel would validate the supplied block sizes and values, copy them into kernel-owned memory, and apply them at the appropriate frame boundary.

The exact Linux 6.19 tree used by this project contains this framework, so a local proof does not need to invent a completely new parameter-buffer mechanism.

### 5.4 Qualcomm Offline Processing Engine

In 2026 Qualcomm posted an open driver for the CAMSS Offline Processing Engine found on Agatti/QCM2290-class platforms, including Arduino UNO-Q/QRB2210 systems.

The v5 proposal provides:

- memory-backed RAW input;
- Bayer processing/debayer;
- color correction;
- scaling;
- NV12 output;
- a V4L2 metadata queue for ISP parameters;
- media-controller entities for input, processing, display/output, and parameters;
- V4L2 compliance testing; and
- a multi-context-ready design, although only one context is instantiated initially.

Published test results show a 3840x2160 RGGB-to-NV12 conversion in approximately 14.9 ms per frame, roughly 67 frames/s, with a stated engine capacity of up to 580 megapixels/s.

This is a major change in Qualcomm's upstream strategy. It provides a concrete open example for:

- defining ISP parameter UAPI;
- validating parameter metadata;
- representing an ISP as media entities;
- scheduling input, parameter, and output buffers; and
- integrating Qualcomm hardware processing with standard Linux interfaces.

### Why OPE cannot simply run on FP3

OPE is a different physical block with different registers and data flow. Its proposed device-tree node is around `0x05c42000` on the target platform. MSM8953's device tree instead exposes VFE40 at `0x01b10000`/`0x01b14000` and CPP at `0x01b04000`.

Therefore:

- enabling the OPE Kconfig option is not sufficient;
- copying its register programming would not work;
- adding an OPE node to the FP3 device tree would be incorrect; and
- VFE40 needs its own parameter and statistics definitions.

OPE is an architectural template, not a compatible driver.

### 5.5 Libcamera CAMSS/OPE work

A proposed libcamera CAMSS pipeline handler introduces a `CamssIsp` abstraction with a software implementation and an OPE-backed implementation. The design can select hardware processing when the OPE media device exists and otherwise fall back to Software ISP.

That abstraction is directly relevant to future FP3 work. A VFE40 implementation could become another CAMSS ISP backend rather than creating an unrelated libcamera pipeline from scratch:

```text
CamssIsp
  |- CamssIspSoft
  |- CamssIspOpe
  `- CamssIspVfe40       (proposed FP3 work)
```

The OPE and libcamera series were still proposed work at the research date, not a stable ABI that should be copied without review.

---

## 6. Source availability and licensing

The technical source material falls into three categories.

### 6.1 Suitable open implementation references

The following are GPL sources and can inform implementation, subject to normal GPL obligations:

- Fairphone's downstream kernel VFE40 driver;
- Fairphone's MSM8953 camera device tree;
- older Linux Foundation VFE40 kernel drivers;
- mainline CAMSS;
- mainline V4L2 ISP helpers; and
- the proposed open OPE kernel and libcamera series.

The Fairphone kernel is especially useful for MSM8953-specific differences such as hardware version checks, UB sizing, clocks, bandwidth, interrupt handling, and register-update behavior.

### 6.2 Proprietary Qualcomm camera source mirrors

Public mirrors exist for portions of Qualcomm's historical `mm-camera2` userspace, including VFE40 modules and statistics parsers. The inspected files carry Qualcomm proprietary/confidential notices and do not provide a licence suitable for incorporation into an open project.

They may demonstrate that a feature existed or help define questions for black-box validation, but code, tables, structure layouts, or tuning values should not be copied from them into a redistributable implementation.

### 6.3 Proprietary binaries and Chromatix

The FP3 vendor partition contains the stock ISP modules, per-sensor Chromatix data, and CPP firmware. There are several practical and legal problems with reusing these directly:

- camera modules are built for Qualcomm's Android/bionic stack;
- they expect the legacy Qualcomm camera event and ioctl interfaces;
- much of the stock camera service is 32-bit;
- tuning formats are private and version-dependent;
- redistribution rights are uncertain; and
- a direct dependency would defeat the goal of an open upstream-style stack.

The preferred tuning strategy is controlled calibration using openly generated YAML/configuration data. Proprietary tuning may be used only where legally appropriate and should not become a build-time or runtime dependency of the open path.

---

## 7. Feasibility assessment

### 7.1 What does not need to be reinvented

A VFE40 hardware ISP project can reuse existing support for:

- sensor control through V4L2 subdevices;
- CSI-2 reception through CSIPHY and CSID;
- media graph routing through ISPIF;
- VFE power, reset, clocks, and interrupts;
- VFE write masters and DMA buffer handling;
- NV12/NV21 and related output-plane handling;
- scaler and crop programming;
- frame sequence tracking;
- libcamera request and algorithm infrastructure; and
- the generic V4L2 ISP parameter-buffer validator.

### 7.2 What must be implemented

The missing engineering work includes:

- advertising Bayer media-bus formats on the VFE PIX sink;
- configuring PIX CAMIF correctly for RAW10/RAW12;
- selecting the Bayer order;
- programming a safe initial Bayer processing pipeline;
- defining VFE40-specific parameter block types;
- adding a parameter metadata output node;
- synchronizing parameter updates to frame boundaries;
- exposing VFE statistics as metadata capture buffers;
- parsing those statistics in libcamera;
- implementing or adapting an IPA/algorithm interface;
- creating per-sensor tuning data; and
- validating bandwidth, width, stride, and dual-VFE behavior.

### 7.3 Overall conclusion

This is not a small libcamera patch. The first functional image likely requires kernel work, and a production-quality implementation spans kernel UAPI, CAMSS, libcamera, algorithms, and tuning.

It is still feasible because the block is already powered and driven by mainline, its register family is known, and the modern API framework now exists. The risk is implementation effort and validation, not a fundamental absence of documentation or hardware.

---

## 8. Proposed implementation architecture

### 8.1 Kernel media topology

A production implementation should expose at least:

```text
sensor -> csiphy -> csid -> ispif -> vfe40_pix -> processed video node
                                      ^
                                      |
                              VFE40 parameter node

vfe40 statistics engine -> VFE40 statistics metadata node
```

Possible raw and processed simultaneous capture should also be investigated:

```text
csid/ispif -> RDI -> raw Bayer video node
           `-> PIX -> VFE40 ISP -> NV12 video node
```

The hardware and downstream stack support raw and processed use cases, but whether the current mainline media graph and resource allocator can route one FP3 sensor to both paths concurrently must be verified on the device.

### 8.2 Parameter queue

The parameters node should use a VFE40-specific metadata format built on the generic extensible V4L2 ISP structures. Each buffer would contain only the blocks that need to change. The driver should retain the last valid value for omitted blocks.

Important requirements include:

- reject invalid lengths and unsupported block types;
- range-check every field before MMIO writes;
- copy userspace data to kernel-owned memory before validation/use;
- apply parameters on a documented frame boundary;
- associate parameter buffers with media requests where possible;
- provide deterministic defaults for the first frame; and
- avoid exposing unrestricted register writes to userspace.

A raw "address/value" ioctl similar to legacy Qualcomm interfaces would be quick but unsuitable for upstreaming and unsafe as a long-term API.

### 8.3 Statistics queue

The statistics node should eventually expose normalized VFE40-specific layouts for the hardware engines needed by libcamera. A minimal sequence would be:

1. BG or BE grids for exposure and white balance;
2. IHIST/BHIST for exposure and tone policy;
3. BF for contrast-detect autofocus;
4. optional RS/CS for flicker or scene analysis.

Buffers must be associated with the correct image frame and parameter set. Frame IDs, SOF timestamps, register-update interrupts, and stats-composite interrupts in the downstream driver provide useful design references.

### 8.4 Libcamera backend

A VFE40 CAMSS backend should:

- configure the raw sensor mode and processed stream together;
- allocate and queue parameter/statistics buffers;
- translate libcamera controls into VFE40 parameter blocks;
- return NV12/NV21 DMA-BUFs to applications;
- run AE/AWB/AF using VFE statistics;
- support manual controls when algorithms are disabled; and
- retain a Software ISP fallback.

The algorithms should be independent of the register layout. Kernel-facing parameter packing belongs in the VFE40 backend; exposure policy and color decisions belong in the IPA/algorithm layer.

---

## 9. Recommended milestones

### Milestone 0: capture a hardware baseline

Before changing the kernel, record the exact runtime topology and working RAW modes:

- `media-ctl -p` for every camera configuration;
- all entity names, pads, and enabled links;
- sensor media-bus formats and Bayer orders;
- RDI V4L2 pixel formats, bytes-per-line, and buffer sizes;
- sensor test-pattern behavior;
- VFE hardware version from kernel logs/register readout;
- clocks and bandwidth votes while streaming; and
- stable raw frame hashes or reference DNGs.

This baseline makes it possible to distinguish CSI/DMA regressions from ISP programming errors.

### Milestone 1: static RAW-to-NV12 hardware proof

The smallest valuable kernel experiment is a fixed pipeline with no userspace parameter API.

Suggested scope:

1. Add a known Bayer RAW10 media-bus format to the VFE PIX sink.
2. Configure CAMIF for the selected sensor dimensions and Bayer order.
3. Enable only the minimum safe ISP stages:
   - raw demux/Bayer pattern;
   - demosaic;
   - unity or fixed white-balance gains;
   - a conservative identity-like CCM;
   - RGB-to-YUV/chroma conversion;
   - output clamp;
   - existing scale/crop.
4. Use a sensor color-bar/test pattern first.
5. Output one conservative NV12 resolution.
6. Disable optional denoise, rolloff, gamma, skin, memory-color, and sharpening blocks initially.

Success criteria:

- repeatable streaming without VFE violations or bus overflows;
- recognizably correct color-bar geometry;
- correct Bayer phase rather than checkerboard/false-color output;
- correct NV12 plane order and stride;
- no stale ping/pong buffers;
- stable start/stop over repeated runs; and
- acceptable frame rate without dropped frames.

This milestone answers the most important hardware question before committing to a UAPI.

### Milestone 2: minimal parameter metadata

Once static conversion works, replace hard-coded values with validated metadata blocks for:

- Bayer pattern/demux;
- black level;
- white balance;
- color correction;
- demosaic; and
- crop/scale.

Associate parameters with requests or document a precise frame-delay model. Validate both unchanged and per-frame-updated settings.

### Milestone 3: initial 3A

There are three possible transitions from fixed settings to automatic algorithms.

#### Option A: temporary fixed controls

Keep exposure, gain, WB, and CCM fixed while validating the image path. This is simplest but only useful under controlled light.

#### Option B: parallel RDI sampling

If the media topology permits simultaneous PIX and RDI routing, use VFE40 PIX for continuous NV12 while occasionally sampling RAW through RDI. Software can calculate simple AE/AWB statistics from those raw frames.

Advantages:

- avoids implementing hardware stats immediately;
- reuses existing libcamera Software ISP/statistics code; and
- provides raw frames for comparison and tuning.

Disadvantages:

- extra DDR bandwidth;
- possible VFE/ISPIF routing limitations;
- added synchronization complexity; and
- CPU/GPU work remains for statistics.

This option must be tested rather than assumed.

#### Option C: native VFE statistics

Implement BG/BE/histogram capture and consume it directly in libcamera. This is the correct long-term design and minimizes memory traffic, but requires more kernel and userspace work.

### Milestone 4: sensor tuning

Add independently generated tuning for each sensor and mode:

- gain conversion and sensor delays;
- measured black levels;
- lens-shading tables;
- illuminant-specific white points;
- color correction matrices;
- gamma/tone policy;
- demosaic thresholds;
- bad-pixel and Bayer filtering thresholds;
- noise-dependent denoise; and
- sharpening limits.

Start with the easiest, best-characterized rear binned mode. Validate all Bayer orders and crop/binning combinations before enabling a tuning profile globally.

### Milestone 5: autofocus

Use the lens actuator controls already available to userspace and expose BF statistics or another focus metric. Implement contrast-detect autofocus before attempting more complex policies.

The important pieces are:

- reliable manual lens position;
- a focus metric correlated with actual sharpness;
- bounded scan/search behavior;
- per-frame lens delay accounting; and
- stable focus windows.

### Milestone 6: CPP post-processing

Treat CPP as a separate later project. A clean driver would likely be a V4L2 memory-to-memory or multi-node processor operating on VFE-produced YUV buffers.

Potential CPP functions include:

- additional scaling/cropping;
- spatial/temporal denoise;
- sharpening;
- rotation or format handling, depending on revision; and
- preparing video frames for another hardware consumer.

CPP is firmware-driven and the stock userspace constructs opaque command payloads. Although the downstream kernel driver is GPL, the command-generation and tuning problem is less clean than the initial VFE40 work. It should not block Bayer-to-NV12 enablement.

---

## 10. Image quality and tuning strategy

A first hardware image can use fixed conservative values, but a usable camera cannot rely on generic defaults indefinitely.

### 10.1 Recommended open calibration process

1. Capture stable RAW frames with known exposure and gain.
2. Measure optical black/covered-pixel behavior where possible.
3. Photograph neutral and color targets under controlled illuminants.
4. Fit WB gains and CCMs from the raw measurements.
5. Generate lens-shading tables from uniform-field captures.
6. Characterize noise against analog gain and exposure.
7. Tune demosaic, bad-pixel correction, denoise, and sharpening conservatively.
8. Compare VFE output against the GPU Software ISP from the same raw scene.
9. Store tuning in a documented, redistributable format.

### 10.2 Role of proprietary Chromatix

Stock Chromatix confirms that Qualcomm/Fairphone tuned every relevant sensor. It can identify which classes of parameters matter, but direct extraction and redistribution may not be lawful and may produce values tied to a different proprietary pipeline revision.

Open calibration is more work but gives:

- known provenance;
- editable values;
- reproducible measurements;
- compatibility with libcamera; and
- a path to upstream or community distribution.

---

## 11. Technical risks and unknowns

### 11.1 Revision-specific register behavior

"VFE40" covers multiple SoCs and revisions. The register map is strongly related, but field encodings, UB sizes, write-master limits, clocking, and workarounds differ. MSM8953-specific downstream checks must take precedence over assumptions from older MSM8974-era code.

### 11.2 PIX raw format and packing

The first implementation must verify:

- CSI RAW10 versus RAW12 selection;
- MIPI packed versus plain/unpacked formats inside VFE;
- the expected bit depth at CAMIF and demux;
- stride/alignment requirements; and
- whether CSID or ISPIF changes packing before VFE PIX.

A wrong packing choice can produce structured but misleading images.

### 11.3 Bayer phase after crop/binning

Bayer order can change after sensor crop offsets, flips, or mode-specific binning. The VFE demosaic pattern must follow the effective first pixel delivered to CAMIF, not merely the sensor model's nominal CFA order.

### 11.4 Maximum line width and dual VFE

High-resolution sensor modes may exceed one VFE's processing width and require split/dual-VFE operation. The first proof should use a known binned mode within a single VFE's limits. Full-resolution still capture should be deferred until the basic pipeline is stable.

### 11.5 Bandwidth and UB allocation

Processed NV12, simultaneous RAW, statistics, and multiple outputs compete for VFE write masters, internal UB storage, and DDR bandwidth. Downstream values are useful references but should not be copied blindly into the mainline clock/interconnect model.

### 11.6 Per-frame synchronization

Sensor controls, lens movement, ISP parameters, and statistics all have different delays. An otherwise correct implementation can oscillate or use stale statistics if frame association is wrong.

### 11.7 Stable UAPI design

A prematurely merged monolithic metadata structure would become hard to extend. The block-based generic V4L2 ISP API should be used from the beginning of any upstream-oriented implementation, even if the first private proof uses temporary fixed registers.

### 11.8 Licensing

Public availability is not equivalent to an open-source licence. Keep implementation provenance clear and base redistributable code on GPL/mainline sources and independently measured behavior.

---

## 12. Validation matrix

The following matrix should be completed before calling the hardware ISP generally usable.

| Area | Required tests |
|---|---|
| Sensors | IMX363, S5K4H7YX, S5KGM1SP, S5K3P9SP |
| Modes | Binned preview first; full resolution later |
| Bayer | All effective RGGB/GRBG/GBRG/BGGR phases used by the modes |
| Packing | RAW10, and RAW12 where exposed |
| Output | NV12 first; NV21/NV16/NV61 only if needed |
| Geometry | No scale, downscale, center crop, odd/even crop boundaries |
| Buffers | MMAP and DMA-BUF where supported; correct strides and plane sizes |
| Lifecycle | Repeated start/stop, sensor switching, error recovery |
| Controls | Exposure, analog gain, WB, CCM, crop, lens position |
| Timing | Parameter-to-frame and statistics-to-frame association |
| Quality | Color chart, neutral gray, low light, highlights, fine detail |
| Performance | Frame rate, dropped frames, VFE clock, DDR bandwidth, CPU load |
| Integration | Simultaneous Emerge DRM/OpenGL display using camera DMA-BUFs |

For each failure, collect:

- kernel CAMSS/VFE logs;
- VFE violation and bus-overflow status;
- media graph state;
- applied sensor/ISP controls;
- raw reference frame where available; and
- the corresponding processed frame.

---

## 13. Relationship to the GPU Software ISP plan

Hardware VFE40 work does not invalidate the current libcamera upgrade plan.

The GPU Software ISP remains useful because it can be enabled and tuned before the kernel hardware ISP is complete. It also provides an independent implementation of demosaic, WB, CCM, gamma, and contrast against which VFE output can be compared.

A sensible long-term policy is:

1. Prefer VFE40 hardware ISP when the kernel exposes a validated parameter/statistics API for the requested sensor mode.
2. Fall back to GPU Software ISP when hardware support is unavailable or incomplete.
3. Preserve RAW capture for calibration, debugging, and applications that explicitly request it.

Output formats also differ:

- the current GPU Software ISP naturally produces 32-bit RGB formats suitable for direct rendering;
- VFE40 is expected to produce YUV formats such as NV12 more naturally;
- Emerge/OpenGL therefore needs an efficient NV12 DMA-BUF import or YUV shader path for the hardware ISP result; and
- NV12 is preferable when feeding a hardware video encoder.

---

## 14. Recommended next action

After the current firmware/display work is stable, create a separate kernel topic branch for a deliberately narrow hardware proof:

```text
MSM8953 VFE40 PIX RAW10 input
+ one rear binned sensor mode
+ static demosaic/WB/CCM/RGB-to-YUV
+ fixed NV12 output
+ no public UAPI yet
+ no automatic statistics yet
```

Do not begin with:

- all four sensors;
- full-resolution dual-VFE capture;
- complete Chromatix-equivalent tuning;
- CPP;
- temporal denoise;
- a permanent raw-register ioctl; or
- upstream submission before the register behavior is validated.

If the static proof succeeds, the project should move immediately toward the generic block-based V4L2 ISP parameter API and a metadata statistics node rather than growing private one-off controls.

The revised strategic conclusion is:

> FP3 hardware ISP support is a worthwhile and credible Linux project. The community has not already completed the MSM8953 VFE40 Bayer pipeline, but mainline infrastructure, GPL reference code, the generic V4L2 ISP API, and Qualcomm's new OPE work have reduced the problem from opaque proprietary integration to a bounded kernel/libcamera engineering effort.

---

## 15. Open questions for device testing

The following questions cannot be settled from source inspection alone:

1. What exact VFE hardware version is read on the FP3/FP3+ at runtime?
2. Which sensor binned mode is safest for the first single-VFE PIX test?
3. Does current ISPIF routing permit simultaneous PIX and RDI from one sensor?
4. What Bayer packing reaches VFE CAMIF after CSID/ISPIF?
5. Which static demosaic classifier values are safe on the MSM8953 revision?
6. Can one VFE produce both preview and still/video outputs under mainline's current resource model?
7. Which statistics engine gives the best minimal input for libcamera AE/AWB?
8. How many frames separate a sensor control update, VFE parameter update, and matching statistics buffer?
9. Does full-resolution S5KGM1SP require dual-VFE split operation?
10. What NV12 DRM/EGL import path is supported efficiently by Freedreno on the FP3?

These should become explicit test cases rather than assumptions in the implementation.

---

## 16. Sources

### Fairphone / MSM8953 downstream

- [Fairphone downstream `msm_isp40.c`](https://raw.githubusercontent.com/FairphoneMirrors/android_kernel_fairphone_sdm632/master/drivers/media/platform/msm/camera_v2/isp/msm_isp40.c)
- [Fairphone downstream MSM8953 camera device tree](https://raw.githubusercontent.com/FairphoneMirrors/android_kernel_fairphone_sdm632/master/arch/arm64/boot/dts/qcom/msm8953-camera.dtsi)
- Local vendor manifests and camera utility sources under `../nerves_system_fp3/`

### Public GPL VFE40 references

- [Linux Foundation GPL `msm_vfe40.h` register and structure definitions](https://git.chaospott.de/tobi/M7350/raw/commit/801e6d2ad8005335413fc75ec2d874055ffb04b4/kernel/drivers/media/platform/msm/camera_v1/vfe/msm_vfe40.h)
- [Linux Foundation GPL `msm_vfe40.c` implementation](https://git.chaospott.de/tobi/M7350/raw/commit/801e6d2ad8005335413fc75ec2d874055ffb04b4/kernel/drivers/media/platform/msm/camera_v1/vfe/msm_vfe40.c)
- [Android kernel `msm_isp40.c` reference](https://android.googlesource.com/kernel/msm.git/+/10a367d9d380ae41ee22b9eb23e17f9b892bab92/drivers/media/platform/msm/camera_v2/isp/msm_isp40.c)

### Mainline Linux APIs and CAMSS

- [V4L2 ISP driver API documentation](https://docs.kernel.org/driver-api/media/v4l2-isp.html)
- [V4L2 extensible ISP userspace API](https://docs.kernel.org/userspace-api/media/v4l/v4l2-isp.html)
- [Qualcomm CAMSS documentation](https://docs.kernel.org/admin-guide/media/qcom_camss.html)
- [MSM8953 CAMSS device-tree binding](https://www.kernel.org/doc/Documentation/devicetree/bindings/media/qcom%2Cmsm8953-camss.yaml)

### Qualcomm open OPE work

- [Qualcomm CAMSS OPE v5 kernel patch series](https://patchew.org/linux/20260724-camss-isp-ope-v5-0-e70ad4fa39ce@oss.qualcomm.com/)
- [Original OPE RFC on lore.kernel.org](https://lore.kernel.org/linux-media/20260323125824.211615-1-loic.poulain@oss.qualcomm.com/)
- [OPE test utility](https://github.com/loicpoulain/camss-isp-m2m-test)
- [Ideas on Board: Qualcomm's first open ISP driver](https://www.ideasonboard.com/news/qualcomm-first-open-isp-driver/)

### Libcamera CAMSS work

- [Libcamera CAMSS pipeline handler series](https://patchwork.libcamera.org/cover/27426/)
- [Libcamera CAMSS OPE implementation patch](https://patchwork.libcamera.org/patch/27431/)
- Local modern libcamera investigation under `../libcamera/`
