# How this driver differs from upstream

This directory is a fork of [`patjak/facetimehd`](https://github.com/patjak/facetimehd).
This file lists what it does that upstream `master` (`c9b063a`, 2026-10-05)
does not, and why. Delete an entry once upstream has it.

Hardware results are from a MacBookAir7,2 with firmware 1.43.0 unless stated;
"Validation" at the end says what that covers.

**Already in both**, so not listed below:
- PLL lock check and PLL/DDR failure propagation.
- Calibration by `DMI_PRODUCT_NAME`, including sensor `0x248`, with all eleven
  `.dat` files declared through `MODULE_FIRMWARE`.
- Controls replayed at `STREAMON`.
- An aspect-correct, centred default crop.
- Odd-width-at-odd-offset crops refused.
- Stepwise frame sizes with an 8-pixel step.
- YVYU withdrawn.
- Up to eight buffers within 16 MiB.
- A 200 ms AE settle.
- Buffers returned when channel start fails.

## Safety and correctness

- Every register and memcpy helper checks BAR bounds.
- Channel descriptors, ring addresses, command responses and buffer returns
  from firmware are validated before use. IRQ retries and ring walks are
  bounded.
- Firmware sees tracked ISP-memory indices and opaque VB2 generation tags,
  never kernel addresses or pointers. Buffer ownership is locked, and invalid
  returns are rate-limited in `dmesg`.
- Scatterlists are walked properly, chained lists and unaligned first segments
  included. This is why `VB2_USERPTR` stays enabled here, while upstream drops
  it.
- A firmware command timeout marks the ISP wedged. Command memory is never
  reused while firmware may still touch it, later commands fail fast with
  `-EIO`, and the next power cycle reloads the firmware.
- Firmware-ring waits are bounded and **non-interruptible**, woken by
  `wake_up()`. A submitted command cannot be cancelled, so a signal must not
  let `STREAMOFF` unmap buffers that firmware still owns.
- Firmware failures reach the VB2 queue as errors instead of leaving readers
  blocked.
- Open file descriptors hold references. Unbind stops streaming before hardware
  is released, so a descriptor that is still open gets `-ENODEV`.
- MSI uses `pci_alloc_irq_vectors()`, without the `IRQF_SHARED` upstream
  requests.

## Power management

- Real runtime and system `dev_pm_ops`. Runtime PM is selected with
  `facetimehd.runtime_pm=1`, which the installer sets:
  - an open file holds a reference;
  - after the last close the camera autosuspends;
  - the next open reloads the firmware.

  The module default leaves the device powered. Upstream has no runtime PM, and
  its system suspend is a full remove/probe.
- **Suspend while streaming continues the stream.** Upstream returns `-EBUSY`
  from suspend whenever any file is open. Here the suspend path parks the
  stream:
  - Suspend stops the channel and frees the ISP-side objects, but keeps the
    queued VB2 buffers owned by the driver, so userspace sees nothing.
  - Resume rebuilds each buffer through `buf_prepare()`, restarts the channel,
    replays the controls and resubmits.
  - Sequence numbers continue. If the rebuild fails, the buffers come back with
    an error (logged as `could not resume capture`).

  This runs in `.resume`, where userspace is guaranteed frozen.
- Shutdown and kexec quiesce DMA, IRQs and streaming without the full remove
  path.
- PCI AER/DPC errors mark the device wedged and wake blocked readers.
- Debugfs is created in `probe()` and removed in `remove()`, never across a
  suspend, because devm entries would leak on every runtime-PM cycle. The
  accessors take a runtime-PM reference instead.

## Pixel formats

**NV12** is the default and enumerated first; YUYV is the only other format.
Upstream offers YUYV alone. Neither offers YVYU, because ISP code 2 writes
invalid chroma.

ISP code 0 is NV12 (4:2:0):
- **Layout.** A `width * height` luma plane, then `width * height / 2` of
  interleaved CbCr in the same mapping. So `bytesperline = width`,
  `sizeimage = width * height * 3 / 2`, and the chroma address is the base plus
  `width * height`.
- **Evidence.** Measured as plane extents, with Cb/Cr means within 0.2 of a
  YUYV capture of the same scene. Whether code 0 is native 4:2:0 or a downsample
  is not established.
- **Why it is the default.** Each frame is three quarters of the YUYV size.
  `ENUM_FMT` index 0, the `TRY_FMT`/`S_FMT` fallback and the probe default must
  all agree, and `tests/script-smoke.sh` checks that they do.

`CISP_CMD_CH_OUTPUT_CONFIG_SET`'s `x2` is the destination row stride, and the
driver passes `bytesperline`. Upstream hardcodes `width * 2`. With a
one-byte-per-pixel plane, that makes the ISP write luma rows at double spacing.
Half the frame comes out blank, with no IOMMU fault.

## Frame rate

`S_PARM` delivers the requested rate exactly. It does this by decimation: one
sensor frame in N goes to userspace, and the rest are handed straight back to
the ISP from a work item.
- `G_PARM` reports `N/30`.
- `ENUM_FRAMEINTERVALS` reports the matching `1/30`–`30/30` stepwise range.
- `S_PARM` works mid-stream.

Upstream programs the ISP's AE frame-rate window (2–30 fps) instead and returns
`-EBUSY` while streaming. Whether that window changes the delivered rate is
unmeasured here: it reads back `7672` (29.97 fps in Q8.8) when set to 30. A
reported rate the stream does not match is what stalls GStreamer's
`pipewiresrc`, so `S_PARM` does not use it until it is measured. The window is
held at 30 fps.

Upstream's `V4L2_CID_EXPOSURE_AUTO_PRIORITY`, which lowers the window minimum
to 5 fps in dim light, is not carried. It would change the sensor rate under
the decimator's fixed 30.

## Cropping

`S_SELECTION` sets `V4L2_SEL_TGT_CROP`, which gives digital zoom and pan.
Upstream has no `S_SELECTION`, and its `G_SELECTION` lacks the `CROP` target.

- **Wire layout.** `CISP_CMD_CH_CROP_SET` is `(x, y, width, height)`.
- **Bounds.** The firmware accepts a window that leaves the sensor array, then
  delivers no frames until it is reloaded. Any user who can open the node could
  use that to deny the camera to everyone else. `fthd_v4l2_set_crop()` therefore
  clamps the origin to `left <= sensor_width - width` and
  `top <= sensor_height - height`. It rounds `left` *down* to 8, so rounding
  cannot push the rectangle back off the array.
- **Odd sizes.** The width is a multiple of 8, so the
  odd-width-at-odd-offset fault cannot occur.
- **Last line of defence.** `fthd_isp_cmd_channel_crop_set()` refuses both
  cases anyway.
- **Never smaller than the output.** Nothing confirms that the scaler upscales.
  `S_FMT` grows a crop that is too small rather than refusing.
- **Refused while busy.** `-EBUSY` while buffers exist, because the rectangle
  only reaches firmware at channel start. `V4L2_SEL_FLAG_GE`/`_LE` get
  `-ERANGE`.
- **Default.** Until `S_SELECTION` sets a crop, it is `CROP_DEFAULT`: the
  largest centred window with the output's aspect ratio. Setting
  `CROP_DEFAULT` explicitly hands control back to the format.
- **Re-fit at channel start.** The rectangle is fitted again there, where the
  real sensor size is first known (848x588 on MacBook8,1, smaller than the
  1280x720 fallback).

## Controls

- `V4L2_CID_POWER_LINE_FREQUENCY` (off, 50 Hz, 60 Hz) uses the firmware
  flicker command.
- `V4L2_CID_EXPOSURE_AUTO` drives firmware AE start/stop. Upstream registers
  it as an auto-only no-op.
- `awb_cct_estimate` (`V4L2_CID_USER_BASE | 0x1003`) is the ISP's own
  colour-temperature estimate. It is read-only and volatile, so
  `v4l2_ctrl_handler_setup()` never replays a SET for it. Warm light reads
  about 2650 and cool light about 5800. It is private, not
  `V4L2_CID_WHITE_BALANCE_TEMPERATURE`, because that control is a set point.
  `0x1001`/`0x1002` are deliberately unused.
- Controls are also replayed after runtime and system resume.
- `VIDIOC_LOG_STATUS` is supported.
- `VIDIOC_CREATE_BUFS` is not advertised: `queue_setup()` does not account
  added buffers against the slot and memory limits. Upstream supports it.

**No firmware setter is registered as a V4L2 control unless its payload is
proven.** `v4l2_ctrl_handler_setup()` sends every registered control's
default at each `STREAMON`. Malformed payloads for the following hard-locked
the host with no panic record:
- AE bias
- manual AWB CCT
- test pattern
- AWB gain
- chroma suppression

So these are not controls, and not hidden behind module parameters either:
- manual exposure
- gain
- manual white balance
- exposure bias
- metering
- sharpness
- test pattern
- backlight compensation
- noise reduction
- chroma suppression

The evidence is in
[`FIRMWARE-REVERSE-ENGINEERING.md`](FIRMWARE-REVERSE-ENGINEERING.md).

## Debugfs

Upstream's debugfs has a single `debug` file. Here, under
`/sys/kernel/debug/facetimehd/<pci-id>/`:

- **Fifteen root-only (`0400`) firmware GETs.** Each one is readable only while
  channel 0 is streaming and fails with `-EPIPE` otherwise. Each holds
  `ioctl_lock` and a runtime-PM reference for one command. There is no
  arbitrary-opcode input. They are named `*_raw` because firmware documents no
  units. What is settled:
  - `sensor_temperature_raw` is always `-1` on this sensor, which means
    unsupported.
  - `ae_frame_rate_{min,max}_raw` read `7672` (Q8.8); `0` means firmware wrote
    nothing.
  - `awb_2nd_gain_raw` is three words, all `4096`, so a unity manual stage.
  - `crop_raw` is the active crop, then the sensor array.
- **Five same-value setters** (`roundtrip_*`, `0200`). The only accepted write
  is `same`, which does GET, SET of the identical value, GET.
- **AE metering tests** (`test_ae_metering_mode[_restart]`). They accept only
  `mode0`–`mode3` and verify the readback.

All of this is scaffolding, not ABI: nothing reaches V4L2 and nothing is
replayed.

## DDR

- The unfinished shmoo calibration (about 500 lines, with unbounded loops) is
  removed. The fixed init sequence remains.
- Probe verifies 256 KiB of DDR instead of 512 bytes. Runtime resume keeps the
  quick check. Verification honours its base address and is clamped to the BAR.

## Kernel integration and logging

- Kernels before 5.15 are not supported. Operation tables are `const` and wire
  structs are `__packed`.
- DDR/PLL bring-up and `FWMSG` are `dev_dbg`, because runtime PM repeats them
  on every resume. Probe logs one `dev_info` line. Failures are `dev_err`.
- CI builds with GCC, strict Clang and Sparse on Ubuntu 22.04/24.04/26.04,
  Fedora 44 and AlmaLinux 10. `tests/hw-validate.sh` covers the hardware side.

## Validation

**Validated** on a MacBookAir7,2, firmware 1.43.0, Ubuntu 7.0 kernels:
- probe and DDR;
- 57/57 applicable `v4l2-compliance` tests;
- NV12 planes checked against YUYV;
- decimation at divisors 1–30, every rate within 1.7%;
- five runtime-PM cycles;
- suspend while streaming, with the viewer continuing;
- `STREAMOFF` on signal;
- every control value, readback and same-value setter;
- metering modes `0..3`.

No run logged a firmware timeout, bad buffer tag, IOMMU fault or oops.

**Not yet run on hardware since the last driver change:**
- `crop-geometry`. The old centred-origin rule (`left <= (sw - w)/2`) matched
  20 of 20 rectangles, and that is exactly what sending `left + width` as the
  width predicts. Confirm that a rectangle flush with the far edge now streams
  and that `crop_raw` echoes `(x, y, width, height)`.
- Eight buffers and the 200 ms AE settle. Both were validated upstream on other
  models.

**Open:**
- Everything above on any machine other than this one MacBookAir7,2.
- Whether NV12 is native 4:2:0 or a downsample.
- Visible effect of anti-banding, exposure mode and metering under controlled
  light.
- Whether the AE frame-rate window can lower the delivered rate.
- Per-frame spacing under decimation (only a coarse bunching check exists).
- Reboot or kexec while streaming.
- Recovery from a real firmware timeout.
- Payloads for the removed controls. See
  [`FIRMWARE-REVERSE-ENGINEERING.md`](FIRMWARE-REVERSE-ENGINEERING.md).
