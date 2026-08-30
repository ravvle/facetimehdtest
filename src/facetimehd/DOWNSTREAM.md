# Downstream changes to the FaceTime HD driver

This directory is the driver built and installed by this project: a fork of
`patjak/facetimehd` commit `364b1c663583e64e27f07ed0257a7584bef095fc`.

The fork carries no patch headers, so this file is the review record for its
divergence from upstream. It describes what the driver does now and why it
differs, not the order in which it got there. A change here is not finished
until this file says why. Remove an entry when the corresponding fix is
accepted upstream.

Everything hardware-dependent below was measured on a MacBookAir7,2 with
firmware 1.43.0 unless stated otherwise; "Hardware validation status" at the
end records what that covers and what it does not.

## Safety and correctness

- All register and memcpy helpers check BAR bounds before accessing hardware.
- Firmware-provided channel descriptors, ring addresses, command responses and
  buffer-return data are validated before use.
- ISP memory objects are identified by tracked indices instead of exposing
  kernel addresses to firmware.
- Scatterlists are walked correctly, including chained lists and unaligned
  first segments.
- VB2 buffers use opaque generation tags rather than kernel pointers. Buffer
  ownership is protected, invalid returns are rate-limited in `dmesg`, and all
  buffers are returned to VB2 on failure paths.
- IRQ retries and ring processing are bounded, fixing a clobbered retry counter
  and preventing unbounded work on malformed firmware data.
- PLL, DDR and memory-verification failures propagate instead of being logged
  and ignored. The inverted PLL lock check is fixed.
- Probe, remove, suspend and resume use symmetric setup and teardown paths.
  Partial ISP initialization is unwound consistently.
- A firmware command timeout no longer lets command memory be reused while slow
  firmware might still access it. A timed-out ISP is marked wedged, later
  commands fail quickly with `-EIO`, and the next power cycle reloads it.
- Firmware failures - stuck IRQs, malformed buffer returns, failed submissions
  - are propagated to the VB2 queue instead of leaving applications waiting
  indefinitely.
- Firmware-ring waits are bounded but **non-interruptible**, paired with
  non-restrictive IRQ wakeups. A submitted firmware command cannot be
  cancelled, so a signal that interrupted the completion wait left STREAMOFF
  releasing VB2/IOMMU mappings that firmware still owned - visible as a failed
  channel stop, unknown buffer tags and DMA writes to unmapped address zero
  when a capturing application was killed. `wake_up_interruptible()` cannot
  wake an uninterruptible waiter, so the completion paths use `wake_up()`.
- Device and debugfs file descriptors hold references to driver state. Unbind
  disconnects V4L2 and stops streaming before hardware resources are released,
  so already-open descriptors fail safely with `-ENODEV`.

## Power management and lifecycle

- The driver provides runtime and system `dev_pm_ops`. Runtime PM is selected
  with `facetimehd.runtime_pm=1`: an open video file holds a reference, after
  the final close the camera autosuspends, and the next open reloads its
  firmware. The module default leaves the PCI device powered, so bare module
  discovery never schedules an ISP/DDR/PCI teardown; the project installer
  enables the validated path explicitly.
- System suspend no longer fails with `-EBUSY` while the camera is streaming.
  Streaming is stopped and the stale ISP mappings are invalidated first.
- A stream that was running when the machine went to sleep is **resumed**
  rather than failed - see "Suspending mid-stream".
- Forced runtime suspend/resume preserves whether the camera was already idle,
  avoiding an unnecessary firmware reload during system resume.
- Debugfs entries are created in `probe()` and destroyed in `remove()`, never
  across a suspend: `debugfs_create_devm_seqfile()` is devm-managed and runtime
  PM cycles the device every few idle seconds, so rebuilding the tree each time
  leaks a devres entry. The accessors take a runtime-PM reference instead.
- Shutdown and kexec quiesce DMA, IRQs and streaming without running the full
  device-removal path while applications may still be open.
- PCI AER/DPC errors mark the device wedged and wake blocked V4L2 users with an
  error instead of leaving them hung.
- MSI setup uses `pci_alloc_irq_vectors()`/`pci_free_irq_vectors()` and no
  longer incorrectly requests a shared IRQ.

## Suspending mid-stream

Upstream errored the vb2 queue on suspend, so `DQBUF` and `poll()` returned
`-EIO` and only `STREAMOFF` plus a fresh `STREAMON` could recover. Most
applications do not attempt that - they report a camera failure - which made
"the camera stops working after suspend" the visible behaviour of closing a
laptop lid during a video call.

Nothing about the hardware requires it. Suspend has to give up the ISP-side
resources, because the power cycle destroys them: the firmware image, the
channel, the S2 IOMMU mapping of every buffer and the descriptor objects that
point at them. But the vb2 buffers are ordinary memory and survive untouched,
and the descriptors are cheap to rebuild - which is what a `QBUF` does on every
frame anyway. So the driver parks the stream instead of failing it:

- `fthd_v4l2_suspend_stop()` stops the channel and frees the ISP-side objects,
  but records the buffers vb2 has handed to the driver and leaves them owned by
  it. The queue is not errored and no buffer is returned, so userspace - frozen
  for the whole transition - has nothing to observe.
- `fthd_v4l2_resume_start()` runs from the system resume callback, after the
  firmware is back and before userspace is thawed. It re-prepares each parked
  buffer through the same `buf_prepare()` path a `QBUF` uses, restarts the
  channel, replays the control values and resubmits the buffers. Capture
  continues into the same buffers the application was already reading.
- Frame sequence numbers continue across the sleep rather than restarting at
  zero. `STREAMON` still resets them; the resume path deliberately does not,
  because the application never asked for a new stream.
- On failure the old behaviour is the fallback: the parked buffers come back
  with an error, the queue is marked, and the application can recover with
  `STREAMOFF`/`STREAMON`. It is logged as `could not resume capture`.
- The shutdown and kexec path keeps the old behaviour, because there is no
  resume coming: a reader blocked in `DQBUF` is better told with `-EIO` than
  left waiting for frames that will never arrive.

The work happens in the `.resume` callback rather than a work item, because
that is the one place where userspace is guaranteed frozen: no `STREAMOFF`,
`close()` or `REQBUFS` can race the rebuild, and the parked buffer pointers
cannot go stale. The cost is that the channel-start command sequence sits in
the device-resume phase - a dozen firmware commands, each bounded by the usual
2 s command timeout - and it is paid only when something actually held the
camera streaming.

## Image geometry

- Lower resolutions use the full sensor array as the crop and ask the ISP to
  scale it down. Upstream cropped the requested dimensions from the top-left,
  producing a zoomed and off-centre picture.
- Sensor dimensions are detected at channel start rather than hardcoded,
  supporting both 1280x720 sensors and the 848x588 array in MacBook8,1.
- Width alignment uses multiples of eight without exceeding sensor limits.
- Crop programming sets `y1` correctly instead of assigning `y2` twice.
- `S_FMT` refuses to change firmware geometry while old-size buffers are still
  allocated or queued.

## Frame-rate selection

Upstream's `S_PARM` accepted any rate, delivered 30 fps regardless, and
reported 30 back so the two at least agreed. An application asking for 15 fps -
what conferencing software and most encoders do to spend less bandwidth - got
30 with no way to tell.

The sensor has one mode and one rate, so the rate is produced by delivering one
frame in N and handing the rest straight back to the ISP:

- The mechanism is deliberately firmware-free. The obvious alternative was the
  ISP's own AE frame-rate window, `CISP_CMD_CH_AE_FRAME_RATE_{MIN,MAX}_SET`,
  which `fthd_start_channel()` already programs. It is the exposure loop's rate
  window rather than a sensor mode, and the sensor keeps delivering 30 fps with
  it programmed. Its readback confirms why: minimum and maximum both read
  `7672`, which is 29.97 fps in Q8.8, so the window is clamped to the sensor's
  single rate. Reporting a rate the hardware does not deliver is the bug that
  made GStreamer's `pipewiresrc` compute negative frame durations and stall
  after one frame; decimation cannot desync that way, because the divisor is
  applied to frames the driver already has.
- `G_PARM` reports `divisor/30` rather than a rounded integer, so 7.5 fps stays
  exact. `ENUM_FRAMEINTERVALS` reports the matching stepwise range - `1/30` to
  `30/30` in steps of `1/30` - which is precisely the set `S_PARM` can honour.
  A discrete list would either omit rates `S_PARM` accepts or advertise ones it
  cannot hit.
- A decimated buffer is never made visible to userspace: it stays owned by the
  driver and is resubmitted from a work item. It cannot be resubmitted inline,
  because `fthd_buffer_return_handler()` runs inside `fthd_irq_work()` and
  `fthd_send_h2t_buffer()` waits on the very channel whose completions that
  same work item processes.
- `fthd_stop_streaming()` and the suspend path `cancel_work_sync()` that worker
  after clearing `channel_running` and before reclaiming buffers. Without that
  ordering a worker already past its state check could hand a buffer back to
  the ISP just as vb2 reclaimed it.

The cost is honest and bounded: the ISP still runs at full rate, so this saves
work in the application and on the bus, not power in the camera.

## Cropping and digital zoom

`S_SELECTION` is implemented for `V4L2_SEL_TGT_CROP`, making the ISP's crop
rectangle settable rather than pinned to the full sensor array. On a
fixed-focus 720p webcam that is digital zoom and pan; the hardware was already
doing crop-and-scale, only the rectangle was constant.

- The crop is never allowed smaller than the negotiated output size, so the
  scaler is only ever asked to shrink. Upscaling is a separate capability and
  nothing here can confirm the ISP has it.
- `S_FMT` grows the crop if the new output would not fit, which is the
  adjustment V4L2 permits and avoids making the result depend on whether the
  format or the selection was set first.
- `S_SELECTION` is refused with `-EBUSY` while buffers exist, because the
  rectangle only reaches the firmware in the channel-start sequence; accepting
  one mid-stream would silently do nothing until the next `STREAMON`.
- `V4L2_SEL_FLAG_GE`/`_LE` are refused with `-ERANGE`. The driver rounds in
  both directions and cannot keep either promise, and returning a rectangle
  that breaks the requested constraint is worse than refusing it.
- `fthd_v4l2_refresh_crop()` re-fits the stored rectangle at channel start,
  which is where the sensor's real geometry is first learned. That keeps a crop
  from surviving into a state the ISP would reject on the 12-inch MacBook,
  whose 848x588 array is smaller than the fallback bounds.

### The crop origin is clamped to the array centre

A rectangle whose origin sits past the centred position would be accepted by
firmware, stored exactly, and then deliver no frames at all - the capture sits
in `vb2_wait_for_done_vb` while the device stays runtime-active, and every
subsequent `STREAMON` returns `-EIO` until the firmware is reloaded. No such
rectangle ever reaches firmware, because `fthd_v4l2_set_crop()` clamps the
origin to:

```text
left <= (sensor_width  - crop_width)  / 2
top  <= (sensor_height - crop_height) / 2
```

Equivalently `left + right <= sensor_width` and `top + bottom <=
sensor_height`: **the crop's centre may not pass the sensor's centre**.
Equality on both axes at once is fine - the centred rectangle streams, so a
clamped crop always streams. The clamp is the fix for the starvation, not a
symptom of it: what an application loses is the framing it asked for, never the
frames.

The containment is structural. `dev_priv->fmt.x1`/`y1`/`x2`/`y2` are written
nowhere but the tail of `fthd_v4l2_set_crop()`, and the one place the rectangle
reaches firmware - `fthd_start_channel()` - calls `fthd_v4l2_refresh_crop()`
immediately before reading those four fields, which routes back through the
same clamp. That second pass is not redundant: `max_w`/`max_h` fall back to
`FTHD_MAX_WIDTH`/`HEIGHT` while the sensor geometry is still unknown, so a
rectangle clamped against the 1280x720 fallback can be past-centre for the
12-inch MacBook's real 848x588 array. Re-fitting once the true geometry is
known is what closes that gap.

The rule is measured, not inferred. Across three crop widths (1280, 640, 320),
three crop heights (720, 360, 240) and offsets from 0 to 640 it predicts 20 of
20 outcomes: at 640 wide the boundary is exactly the centred `left = 320`
(`328` starves), at 320 wide it is `480`, which rules out a fixed offset limit,
and vertically it is exact to a single pixel (`top` 180 streams, 181 starves) -
the driver rounds `left` to eight pixels but leaves `top` alone, so that axis
asks the finer question. A crop GET taken from a starving stream returns
exactly the rectangle that was programmed, so firmware is neither rejecting the
geometry nor silently adjusting it; the fault is downstream of crop
programming, and root-causing it needs the firmware's own log at `dyndbg=+p`.

It clamps rather than refusing because `S_SELECTION` is an adjusting call and
this function already adjusts - it rounds the width, aligns `left` to eight
pixels and enforces a floor at the output size. `G_SELECTION` reports what was
programmed, so an application can see exactly what it got.

The deciding argument for handling it in the driver at all was reachability:
`S_SELECTION` is available to any local user who can open the video node, so
leaving it unhandled let an ordinary application - buggy or hostile - deny the
camera to every other process until it closed the device. It is not a kernel
fault (across 25 deliberate wedges there was no oops, call trace, IOMMU or DMAR
fault, and with runtime PM enabled every one recovered once the device went
idle), but "recovers when the offender lets go" is a poor contract for a shared
device.

**The `ALIGN`-then-cap order in that function is load-bearing.** `ALIGN` rounds
up, and the centred maximum need not be a multiple of eight - `(848 - 648) / 2`
is `100` on the 12-inch MacBook's array - so rounding `100` up to `104` would
produce precisely the past-centre rectangle the clamp exists to prevent.
`tests/script-smoke.sh` asserts the ordering, not just the presence of a clamp.

The limit derives from `sensor_width`/`sensor_height` and the requested crop
size rather than a constant, so a model with a different array gets its own.
Note that the clamping can produce a starving-shaped request from one that does
not look like it: `left=648, width=632` rounds to `+640+0` 640x360.

## Pixel formats

**NV12**, YUYV and YVYU are advertised, in that order. The ISP's semi-planar
output, format code 0, is NV12 - 4:2:0, not the 4:2:2 that upstream's 2015
comment ("plane 0 Y plane 1 UV", with no sampling given) was read as for a
decade. NV16 is not offered: no output-format code produces it.

NV12 is the default: `ENUM_FMT` index 0, what `TRY_FMT`/`S_FMT` coerce an
unsupported request to, and what a freshly probed device reports through
`G_FMT`. All three are the same value on purpose - a default that is not
enumerated first is how an application negotiates a format nobody tested. It
was enumerated last while the 4:2:0 sizing was still new on this hardware; the
validation below is what moved it to the front.

Two things put it there, and they are not equally strong. The measured one is
size: 1.5 bytes per pixel against 2, so a frame is three quarters of the packed
one, in DMA and in whatever copies it afterwards. The other is a judgement
about who reads index 0 - anything that negotiates walks the whole list and
names its format, so ordering does not reach it, while the simple code that
does take index 0 is mostly feeding a display or a 4:2:0 encoder that would
have downsampled the chroma regardless. Neither packed format was withdrawn, so
an application that names one is unaffected.

It is tempting to add that code 0 is the ISP's native output and the packed
formats are a conversion on the far side of it. **That is not established.**
The evidence for 4:2:0 is plane extents plus chroma means matching a YUYV
reference, and a mean cannot distinguish native 4:2:0 from a downsample of a
true 4:2:2 chroma stream. The ordering argument above does not rest on it.

The sampling is a hardware result. Capturing through code 0 and mapping the
frame row by row gives a `width * height` luma plane followed by exactly
`width * height / 2` of chroma - 360 chroma rows for a 720-row frame - with the
remaining 460,800 bytes of an NV16-sized buffer never written. Splitting that
chroma gives Cb 122.3 / Cr 135.3 against 122.5 / 135.4 from a YUYV capture of
the same scene, and luma 93.1 against 92.9. The layout is therefore:

```text
bytesperline = width
sizeimage    = width * height * 3 / 2
ISP addr0    = mapped buffer base
ISP addr1    = mapped buffer base + width * height
```

`iommu_allocate_sgtable()` gives each buffer one contiguous run of S2 IOVA
pages, so the chroma plane is a byte offset into the same mapping and needs no
second one. The vb2 queue stays single-planar, with the semi-planar case
derived from the pixel format at each use rather than cached in a plane count -
a cached count is what once asked a `V4L2_BUF_TYPE_VIDEO_CAPTURE` queue for two
planes.

The 4:2:0 sizing is the part that must not regress. Reading chroma over a 4:2:2
extent averages it with unwritten zeros and reports a number that looks like a
wrong format rather than a wrong size.

### The output-config stride

`CISP_CMD_CH_OUTPUT_CONFIG_SET`'s `x2` is the destination row stride in bytes,
not the "chroma size?" upstream guessed. Upstream hardcoded `width * 2`, which
for the packed formats is simultaneously a correct stride and an unremarkable
constant, so nothing distinguished the two readings until a one-byte-per-pixel
plane arrived: the ISP then wrote luma rows 2560 bytes apart into a buffer laid
out for 1280, leaving exactly 50% of the luma plane zero in a strict
every-other-row pattern.

**That failure raised no IOMMU fault** - `sizeimage` still covered everything
written, because the ISP skips rows rather than overrunning - so it was silent,
and only inspecting the planes separately found it.
`fthd_isp_cmd_channel_output_config_set()` now takes the stride and is passed
`bytesperline`. For YUYV and YVYU that is `width * 2`, so the command is
byte-for-byte what it always was.

Two silent-failure lessons are built into `tests/hw-validate.sh --only nv12` as
a result. A capture check that tests only size and exit status cannot tell
these formats apart: the format was once absent from `ENUM_FMT`, `S_FMT`
silently coerced the fourcc, and both formats had the same byte count, so the
"pass" was really YUYV. `v4l2-ctl` also exits 0 when `VIDIOC_STREAMON` fails.
The section therefore re-reads `G_FMT` and requires the fourcc to survive,
counts blank luma rows, and compares chroma against a YUYV capture of the same
scene rather than an absolute threshold.

## V4L2 API and controls

- `S_PARM`, `G_PARM` and frame-interval enumeration consistently report the
  frame rate the driver actually delivers.
- Frame-size enumeration reports the same stepwise range accepted by
  `TRY_FMT`/`S_FMT`, and frame-interval enumeration validates both format and
  minimum/maximum dimensions.
- `G_SELECTION` reports the active crop for `V4L2_SEL_TGT_CROP` and the
  detected full sensor rectangle for the default and bounds targets.
- V4L2 controls are replayed after the ISP channel starts, so values set before
  `STREAMON` and across runtime-PM cycles take effect. Hardcoded brightness and
  contrast resets were removed, saturation/hue/white balance are restored, and
  the white-balance fall-through and unknown-control handling are fixed.
- Unsupported `VIDIOC_CREATE_BUFS` is no longer advertised. The hardware has a
  fixed four-buffer pool, so pretending it could grow returned misleading
  results.
- `VIDIOC_LOG_STATUS` reports cached control values through the standard V4L2
  helper.
- Fixed-size V4L2 names use bounded `strscpy()` calls.
- `V4L2_CID_POWER_LINE_FREQUENCY` exposes disabled, 50 Hz and 60 Hz
  anti-banding through the firmware flicker-frequency command, and
  `V4L2_CID_EXPOSURE_AUTO` the firmware's automatic/manual exposure start and
  stop. Firmware accepts every value for both and capture continues after a
  change; their visible effect under controlled lighting is still a validation
  target.

### Calibration selection

Calibration selection uses the correct DMI product and vendor fields; MacBook
Air systems request their intended `1771_01XX.dat` rather than falling back to
`1871_01XX.dat`. All nine possible sensor calibration files are declared with
`MODULE_FIRMWARE`, so initramfs tools and `modinfo` can discover them. Missing
calibration is non-fatal but produces incorrect colours, and
`extract-firmware.sh` currently recovers only four of the nine - the ones
reachable inside the single `AppleCamera.sys` a calibration layout is recorded
for - so a machine needing one of the other five gets none until an offset
table is added for a driver binary that carries it.
`fthd_isp_cmd_set_loadfile()` logs the filename it wanted whenever the request
comes back empty, so that gap is visible in `dmesg` rather than silent.

### The colour-temperature control

`FTHD_CID_AWB_CCT_ESTIMATE` (`V4L2_CID_USER_BASE | 0x1003`, printed by
v4l-utils as `awb_cct_estimate`) reports the ISP's own current
colour-temperature estimate from `CISP_CMD_CH_AWB_CCT_GET`. It is the one
firmware value recovered during the lockup investigation that reaches the
ordinary V4L2 surface, and three things justify that.

**Why it is safe to register.** The rule the removed controls broke is that
`v4l2_ctrl_handler_setup()` replays every registered control's default at each
`STREAMON`. This control is `V4L2_CTRL_FLAG_READ_ONLY`, and `handler_setup()`
skips read-only controls outright - so registering it adds a GET an application
may ask for and no SET the framework can ever replay. That is a structural
guarantee rather than a convention, and `tests/script-smoke.sh` asserts the
flag.

**Why the unit is not a guess.** Under warm light this firmware reports around
`2652` and under cool light `5777`, with the right ordering and realistic
magnitudes; the value tracks lighting and not exposure. Cross-model
confirmation is still open, which is part of why it is a private CID.

**Why not `V4L2_CID_WHITE_BALANCE_TEMPERATURE`.** That control means the
temperature an application asks the camera to *assume*: writable, paired with a
manual AWB mode. This is a measurement the ISP produces, and the manual AWB-CCT
setter carries a second payload word whose meaning is unidentified, so there is
nothing to write. Publishing a measurement under a CID that means a set point
would make an application that wrote it silently get nothing. `0x1001` and
`0x1002` are deliberately skipped: they belonged to the removed
noise-reduction and chroma-suppression controls.

The control is volatile, so `g_volatile_ctrl` issues the GET on demand under a
runtime-PM reference. It does not take `ioctl_lock`, because `vdev->lock` *is*
`ioctl_lock` and `video_ioctl2()` already holds it - which is also what
serialises this against the debugfs readbacks. On an idle camera it reports the
last value sampled while streaming rather than failing or powering the ISP up:
a diagnostic read is not a reason to retrain DDR and re-upload firmware, and
returning an error there would fail `v4l2-compliance` for no gain.

### Removed inferred firmware controls

The manual-exposure, manual-white-balance and image-quality controls added by
the post-`20bdd61` feature series (`953fe61`-`8e154f9`) are removed, along with
the module parameter that gated them. Registering them made
`v4l2_ctrl_handler_setup()` send every default command at ordinary `STREAMON`,
and that build repeatedly hard-locked the MacBookAir7,2 - the whole machine,
with no panic or pstore record. Firmware disassembly then proved several
payloads malformed rather than merely untested: AE bias submitted a request
four bytes shorter than the fields firmware reads, AWB CCT manual omitted its
second word, the test pattern put its value in the wrong halfword, the AWB
first-gain helper was structurally wrong, and chroma suppression consumes three
independent bytes that no single generic strength can honestly represent.
Complete wire-layout evidence is in
[`FIRMWARE-REVERSE-ENGINEERING.md`](FIRMWARE-REVERSE-ENGINEERING.md).

A module parameter is not adequate containment for a command capable of
freezing the host, so the gate went with the interfaces. Specifically removed:
`V4L2_CID_EXPOSURE_ABSOLUTE`, `V4L2_CID_GAIN`,
`V4L2_CID_WHITE_BALANCE_TEMPERATURE`, `V4L2_CID_AUTO_EXPOSURE_BIAS`,
`V4L2_CID_EXPOSURE_METERING` (whose established fixed mode 3 is restored),
`V4L2_CID_SHARPNESS`, a `V4L2_CID_TEST_PATTERN` menu,
`V4L2_CID_BACKLIGHT_COMPENSATION` over `CISP_CMD_CH_DRC_SET`, and private
noise-reduction and chroma-suppression controls at `V4L2_CID_USER_BASE |
0x1001` and `| 0x1002`.

The stable brightness, contrast, saturation, hue, automatic white balance,
anti-banding and automatic/manual exposure switches remain and use their
hardware-tested command paths.

Do not restore any of this without reading `FIRMWARE-REVERSE-ENGINEERING.md`
first. Two of the removals are worth keeping available as future work: a test
pattern is the only way to separate "the sensor or firmware is not producing
frames" from "the ring, the IOMMU mapping or buffer return is broken" without a
lit room or a subject, and denoising must not be mapped onto
`V4L2_CID_IMAGE_STABILIZATION` - a private control with an honest name beats a
standard one with an invented meaning.

## Firmware readbacks and test scaffolding

The governing rule since the lockups is: **GET first, and a recovered value
reaches V4L2 only as a read-only control once its meaning is established.**
Everything below that has no established meaning stays in debugfs.

Fifteen confirmed GETs are exposed as mode-`0400` debugfs files under
`/sys/kernel/debug/facetimehd/<pci-id>/`, readable only while channel zero is
already streaming: `sensor_temperature_raw`, `awb_cct_raw`, `ae_bias_raw`,
`ae_gain_cap_raw`, `ae_gain_cap_min_raw`, `ae_gain_cap_max_with_exp_raw`,
`ae_gain_cap_off_raw`, `ae_integration_time_max_raw`,
`ae_sensor_integration_time_min_raw`, `ae_sensor_integration_time_max_raw`,
`ae_metering_mode_raw`, `ae_frame_rate_max_raw`, `ae_frame_rate_min_raw`,
`awb_2nd_gain_raw` and `crop_raw`. Each read takes `ioctl_lock`, requires a
running channel, holds a runtime-PM reference for exactly one command, and adds
nothing to `STREAMON` or resume. An idle read fails with `-EPIPE`; nothing
polls, and there is no arbitrary-opcode input. They are named `raw` because
firmware documents no units or ranges. `tests/script-smoke.sh` asserts the
`0400` mode and the absence of any V4L2 path for them.

Nominal GET slots for sharpness, noise reduction, chroma suppression and DRC
are **not** exposed: this firmware's dispatcher routes those opcodes to its
unsupported-command block even though the names exist in the recovered enum.
Every image-processing setter it does implement is therefore write-only, with
no way to restore a default except by reloading firmware.

Three of these readbacks are closed questions rather than open ones:

- **`sensor_temperature_raw` returns `-1` on this sensor, always.** Cold after
  boot, after ten minutes of continuous streaming, and under bright, dark, warm
  and cool light. A physical scale, however unknown, would have moved with die
  temperature over that stream, so `-1` is a not-supported sentinel.
  `FTHD_SENSOR_TEMPERATURE_NONE` names it and the file prints
  `-1 (unavailable)` - raw number first, so anything parsing the file keeps
  working. hwmon registration would be wrong even on a sensor that returns
  something else, because that ABI requires millidegrees Celsius and no reading
  here establishes a unit.
- **`ae_frame_rate_max_raw`/`ae_frame_rate_min_raw` both read `7672`**, which
  is 29.97 fps in Q8.8 (`7672 / 256 = 29.96875`; NTSC `30000/1001` truncates to
  `7672`), independently corroborating the Q8.8 encoding on a quantity whose
  true value was measured by decimation timing. Minimum equal to maximum means
  the window is clamped to the sensor's single rate - the readable reason
  behind the behavioural conclusion in "Frame-rate selection". A caveat is part
  of the interface: both handlers compare a channel-context field against
  `0xffff` first and take a path that never writes the response word when it
  matches, and `fthd_isp_cmd()` leaves the caller's buffer alone in that case,
  so a zero means "firmware wrote nothing", not "zero frames per second". The
  file says so on the line.
- **`awb_2nd_gain_raw` returns three words, not the two an R/B reading would
  predict**, so the values are printed positionally with no colour named. All
  three read exactly `4096` while the CCT estimate reported `2785` - markedly
  warm light, in which a live gain triple cannot be equal on all three
  channels. It is a manual stage sitting at unity, which the dispatcher sweep
  supports (`0x30c` 2nd-gain manual is implemented, `0x30b` its adaptive
  thresholds is not). Unlike `awb_cct_estimate` there is no evidence it
  measures anything, so it gets no CID.

**`crop_raw` returns the active crop and the sensor array**, eight words where
`CISP_CMD_CH_CROP_SET` sends four. The first group tracks the programmed crop
exactly; the second stays at `0 0 1280 720` across every rectangle tested,
which is the full array. Both are in the `(left, top, right, bottom)` form the
setter uses. The struct names them `rect1`/`rect2` by position rather than by
meaning, because that identification is one machine's. It confirms from the
ISP's side that a crop took effect and reads the array bounds without inferring
them; it carries no differential information about why a past-centre rectangle
starves, since the first group only echoes the geometry in effect and the
second is constant.

### Same-value setters and the metering harness

Five root-write-only mode-`0200` nodes support controlled setter validation:
`roundtrip_ae_bias`, `roundtrip_ae_metering_mode`,
`roundtrip_ae_integration_time_max`, `roundtrip_ae_gain_cap` and
`roundtrip_ae_gain_cap_min`. They accept no numeric input - the only valid
write is the literal word `same`. Under `ioctl_lock` and an active-stream
check, the kernel GETs the current value, SETs that exact value once, GETs
again, and fails on mismatch. Userspace cannot choose an out-of-range value or
make two gain limits cross, and nothing happens at module load, `STREAMON` or
resume.

`test_ae_metering_mode` and `test_ae_metering_mode_restart` are the one
non-current-value experiment, deliberately limited to AE metering modes `0..3`
- the closed domain recovered from this firmware, whose mode `3` the
established channel-start sequence already programs. They accept only the fixed
tokens `mode0` through `mode3`, reject numeric parsing, and verify the mode
reads back exactly. The `_restart` variant stops AE, sets the mode, restarts AE
and re-GETs, because the normal channel sequence programs metering before AE
starts while the plain node mutates it with AE already running.

All of this is scaffolding, not ABI: no V4L2 control is registered and nothing
is replayed. Remove it or keep it debug-only once the command semantics are
established.

## DDR handling

- Roughly 500 lines of unfinished, unused DDR shmoo calibration code were
  removed. The deleted implementation contained incomplete stages, ineffective
  timeouts and potentially unbounded loops; the original is in the upstream
  commit linked above.
- DDR continues to use the fixed hardware initialization sequence, memory
  verification and saved PHY registers used for runtime resume.
- Probe verification was widened from 128 words (512 bytes) to 65,536 words
  (256 KiB), giving meaningful address-line coverage without materially slowing
  startup - total module load stays around 640 ms. Runtime resume retains the
  smaller fast check.
- Memory verification honours its base address, clamps the requested range to
  the mapped BAR, and no longer describes a small sample as a "full" check.

## Kernel integration, diagnostics and testing

- Compatibility branches older than the supported Linux 5.15 CI floor were
  removed.
- The code uses current runtime-PM, PCI BAR, MSI and V4L2 interfaces. Operation
  tables are `const`, firmware wire structures are `__packed`, and long waits
  sleep rather than busy-wait.
- The DDR/PLL bring-up messages are `dev_dbg`, as is `FWMSG`, the firmware's
  own console. They read like once-per-boot banners, but runtime PM re-runs
  `fthd_hw_init()` on every resume, so at `dev_info` they wrap a default kernel
  ring buffer in a minute or two and evict everything else - including the
  driver's own suspend records. Probe prints one `dev_info` summary line
  instead (`camera ready: DDR 450 MHz, 64-bit DMA`); `dyndbg=+p` brings the
  detail back. Failure messages moved the other way, `dev_info` to `dev_err`.
- CI performs warning-clean Clang builds and Sparse semantic checks through
  `tests/build-driver.sh`.
- `tests/smoke-capture.sh` checks the V4L2 surface on real hardware.
  `tests/hw-validate.sh` runs probe, timing, controls, frame-rate decimation,
  cropping, NV12, runtime PM, suspend, firmware-wedge evidence and the
  readbacks by default; `readback-profile`, `roundtrips`, `metering-modes` and
  `crop-geometry` are opt-in via `--only`, and the two-phase reboot test needs
  `--reboot`. Anything that mutates firmware state is opt-in.
- `tests/script-smoke.sh` covers the installer plumbing that shellcheck cannot
  see, including that every source file in this directory is listed in the
  Makefile - the failure that compiles in no CI job and only shows up on a
  user's machine.

## Hardware validation status

Validated on a MacBookAir7,2, firmware 1.43.0, Ubuntu kernels in the
7.0.0-generic series, against the DKMS build:

- clean probe and DDR initialization, including the widened probe check;
- 30-frame capture, 57/57 applicable `v4l2-compliance` tests, and capture after
  every retained control value;
- YUYV, YVYU and NV12, each with the fourcc surviving `G_FMT`, the NV12 planes
  inspected separately at their 4:2:0 extents against a YUYV reference;
- NV12 as the format nobody negotiates: a freshly loaded driver reports it,
  `ENUM_FMT` offers it at index 0, and the suite runs end to end from that
  starting state, so every section above is measured through the semi-planar
  layout an application gets by taking whatever comes first;
- frame-rate decimation at divisors 1, 2, 3, 5, 10 and 30, every measured rate
  within 1.7% of the request and `G_PARM` reporting the divisor-derived rate
  exactly, with nothing starving even at divisor 30 (29 of every 30 frames
  recycled through a pool of four buffers);
- crop with a non-zero origin honoured - `+8+8` and the full array produce
  clearly different frames - aligned rectangles reading back exactly, and the
  centre rule above verified at eight-pixel resolution horizontally and one
  pixel vertically;
- repeated runtime suspend, firmware reload and capture recovery over five
  consecutive cycles, with debugfs access waking a suspended camera and the PCI
  runtime counters advancing normally;
- system suspend while streaming, with the original viewer continuing to
  receive frames after resume without reopening the device;
- signal-time STREAMOFF on a live stream completing in 715 ms with an immediate
  30-frame recovery capture;
- firmware acceptance of all anti-banding and exposure-auto values;
- all fifteen readbacks and all five same-value setters, individually, each
  with the stream surviving, capture restarting, runtime resume capturing;
- AE metering modes `0..3` accepted, read back, restored and teardown-safe.

None of those runs logged a FaceTimeHD warning, firmware timeout, channel-stop
failure, invalid or unknown buffer tag, IOMMU/DMAR fault, oops or call trace.

Still open:

- **Every one of the above on any other machine.** This is one MacBookAir7,2,
  one sensor and one kernel series; the rest of the 2013-2015 range rests on
  code review and on a sensor-detection path only exercised on that sensor.
  Specifically model-dependent: NV12 and its sampling, the `crop_raw` second
  rectangle being the sensor array, the crop centre rule, and
  `awb_cct_estimate` reading kelvin (read-only, so a wrong unit misinforms
  rather than misconfigures).
- **Whether code 0 is the pipeline's native sampling**, or a downsample of a
  genuinely 4:2:2 chroma stream. Every measurement so far is of what the ISP
  wrote - plane extents, and chroma *means* agreeing with a YUYV reference -
  and means are identical either way. It decides nothing about the format's
  correctness and nothing about the enumeration order; it decides whether an
  application that takes index 0 and displays it is losing chroma detail that
  YUYV would have kept. `FIRMWARE-REVERSE-ENGINEERING.md` describes the
  capture that would settle it: fine horizontal chroma structure, compared
  chroma row against chroma row in both formats rather than by mean.
- The visible effect of anti-banding and exposure mode under controlled light.
  `controls.ae.effect` compares a manual and an auto reading of the same dimmed
  scene, so it needs a *partial* attenuation held steady across both. A hand at
  the lens does not give one - it either misses the lens, leaving the manual
  reading as bright as the lit one, or covers it completely and floors both
  readings at 0.0 luma, where auto-exposure has no signal to amplify and
  neither setting can be told from the other. Dimming the room, or a
  translucent diffuser laid over the lens, is the stimulus the check wants. Its
  guards report an unusable stimulus as such, so AE is unmeasured here rather
  than recorded as working or broken.
- Whether AE metering modes `0..3` are visibly distinct. They are accepted and
  persistent, but across a controlled high-contrast scene the largest cross-mode
  spreads were 1.2 luma full-frame, 0.7 central-spot and 1.5 outer - compatible
  with capture noise. Not enough to map them onto the standard V4L2 menu.
- Per-frame spacing under decimation. The mean rate is correct at every
  divisor, but `hw-validate.sh` checks only a coarse bunching floor, so uneven
  spacing at the right average would pass.
- Why a past-centre crop rectangle starves the stream. The clamp makes it
  unreachable through the ABI; the cause is downstream of crop programming and
  needs `dyndbg=+p`. Two further crop questions are not reachable through this
  ABI at all and are not attempted: the driver rounds the rectangle before the
  ISP sees it, so a finer alignment cannot be requested, and it refuses a crop
  smaller than the output, so whether the scaler would upscale cannot be asked.
- Orderly reboot or kexec while actively streaming.
- Recovery from a real firmware command timeout, which has not been reproduced.
- Whether any supported sensor returns something other than the `-1`
  temperature sentinel, and its scale if so.
- Any future reimplementation of manual exposure, white balance, exposure bias,
  sharpness, test pattern, backlight compensation, noise reduction or chroma
  suppression. Recovered layouts and remaining semantic questions are in
  `FIRMWARE-REVERSE-ENGINEERING.md`.
