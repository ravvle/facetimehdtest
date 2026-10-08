# FaceTimeHD firmware command notes

Facts recovered from the camera firmware, kept separate from guesses about
them. Do not turn an item marked **unknown** into a userspace ABI without new
evidence and a hardware test; the rules at the end of this file exist because
doing so once froze the validation machine outright.

## Image examined

- Host: `MacBookAir7,2`, Broadcom FaceTime HD `14e4:1570`, Ubuntu
  `7.0.0-29-generic` x86-64
- File: `firmware.bin` extracted for the machine (not tracked by this project)
- SHA-256: `e3e6034a67dfdaa27672dd547698bbc5b33f47f1fc7f5572a2fb68ea09d32d3d`
- Size: 1,425,412 bytes
- Embedded version strings: `S2ISP-01.43.00`, `H4ISPAPPLE`, `H4ISPCD`,
  `A4.5.5.1 release`
- Format: raw little-endian ARM image. The vector table begins in ARM mode and
  the command implementation is Thumb-2.

All firmware addresses below are offsets in that exact image. They are useful
for reproducing the analysis but must not be assumed stable across firmware
versions. Every hardware value below is from that one machine.

## Reproduction

The useful Ubuntu packages are `binutils-arm-none-eabi`, `radare2` and
`gdb-multiarch` (used here: objdump `2.45.50.20251209`, radare2 `6.0.7`, GDB
`17.1`). Static inspection submits nothing to the live ISP.

```text
sha256sum firmware.bin
strings -a -t x firmware.bin
arm-none-eabi-objdump -D -b binary -m arm -EL -M force-thumb firmware.bin
r2 -q -2 -a arm -b 16 -e cfg.bigendian=false \
   -c 'aaa; pdc @ 0x47530' firmware.bin
```

Radare2 identifies the main channel-command dispatcher as the Thumb function at
`0x47530`, analysed control-flow range `0x47530..0x68bf6` (many non-contiguous
basic blocks). Apple-private commands use a separate dispatcher at `0x70f0`
with its table at `0x7910`.

String cross-references come from searching the image for a string address
encoded as a little-endian 32-bit value, then finding the Thumb PC-relative
load of that literal. The AE-bias log string, for example, is at `0xa9384`, its
pointer at `0x4a490`, loaded by the dispatcher at `0x49a2e`.

## Wire framing

Linux sends an eight-byte `isp_cmd_hdr`, followed by the command payload:

```text
command+0x00  u32 unknown0
command+0x04  u16 opcode
command+0x06  u16 status
command+0x08  u32 channel             (for per-channel commands)
command+0x0c  first command field
```

Confirmed both by `struct isp_cmd_hdr` and by the firmware dispatcher, which
reads the opcode at `command+0x04`, routes the channel from the first payload
word, and accesses command-specific data from `command+0x0c` onward.

**The dispatcher does not enforce a minimum request length per opcode.** A
short Linux payload can therefore make firmware read past the submitted object;
a malformed request is not reliably rejected. That invalidates the safety claim
the removed feature series rested on.

## Why the inferred controls were removed

Registering a V4L2 control makes `v4l2_ctrl_handler_setup()` submit its default
setter at every `STREAMON`, so a user did not have to touch an experimental
control to trigger its firmware traffic. The feature series that added
manual-exposure, manual-white-balance and image-quality controls therefore
replayed AE bias, sharpness, test pattern, DRC, noise reduction and chroma
suppression on every ordinary stream start, and repeatedly hard-locked the
whole machine with no panic or pstore record. Disabling runtime PM and hwmon
registration each failed to prevent it; `module_blacklist=facetimehd` reliably
recovered the system, and a build with the experimental interfaces removed
booted, captured and passed 57/57 applicable `v4l2-compliance` tests.

Disassembly then showed the requests were malformed rather than merely
untested — see the layout table below. AE bias is the clearest memory-safety
defect: firmware reads a tag word beyond the end of Linux's request. The
strongest statement the evidence supports is that **automatic replay of
malformed or semantically guessed firmware commands caused the lockups**,
with AE bias the leading individual candidate. Naming it as the sole cause
would need a controlled one-command reproduction, which is an unnecessary
whole-machine risk. Test-pattern values landed in the wrong halfword and chroma
suppression omitted two meaningful parameters, but both stayed inside the word
Linux supplied, so neither is a memory-safety defect on its own.

A module parameter is not adequate containment for a command that can freeze
the host, so the gate was removed with the interfaces rather than left behind
it.

One installer defect surfaced in the same audit and is fixed: `install.sh
--status` reported a resident module as unloaded, because `lsmod | grep -q`
under `set -o pipefail` turns an early grep exit into a SIGPIPE failure.
Module-lifecycle checks read `/sys/module/facetimehd` instead.

## Recovered command layouts

`+0xNN` offsets are from the start of the complete command, including the
eight-byte header.

| Opcode | Command | Firmware evidence | Consequence for the attempted driver API |
|---|---|---|---|
| `0x8208` | Apple AE flicker-frequency set | Apple dispatcher block `0x8e4a`: reads one word at `+0x0c` and forwards it to wrapper `0xca2c`. | The existing `u32 channel; u32 frequency` layout is correct. Hardware accepted `0`, `50` and `60`; static analysis does not prove their visible anti-banding effect. |
| `0x204` | AE bias exposure set | Block `0x49a04`: reads a halfword at `+0x0c` and a word at `+0x10`; log at `0xa9384` prints both as `bias` and `tag`. | Payload is at least `u32 channel; u16 bias; u16 reserved; u32 tag`. The attempted `u32 channel; s32 bias` was four bytes short, omitted the tag, treated the bias as signed milli-EV without evidence, and made firmware read beyond the request. Leading lockup candidate. |
| `0x20f` | AE integration time set | Handler ending at `0x4ab84`; reads a word at `+0x0c`. Log at `0xa903b`. | `u32 channel; u32 value` has the correct size and offset. The microsecond unit is unproven. |
| `0x20c` | AE gain-cap set | Block `0x49b1e`: reads a word at `+0x0c`; log at `0xa9206`. | `u32 channel; u32 value` is structurally correct. The `0..255` V4L2 range and use as a manual sensor-gain control are not proven. |
| `0x22e` | AE minimum gain-cap set | Block `0x49f92`: reads a word at `+0x0c`; log at `0xa922f`. | The individual payload shape is correct. Pinning gain by writing minimum then maximum was an inference; it may transiently make min exceed max and is unvalidated. |
| `0x305` | AWB CCT manual | Block `0x4a7c6`: copies words at `+0x0c` and `+0x10` into an eight-byte internal request; log at `0xa8e9a`. | Payload is `u32 channel` plus two words. The attempted helper supplied only `channel + cct`, so the second word was read beyond the request. That word is plausibly a tag, but the name and the kelvin interpretation are unproven. |
| `0x311` | AWB first-gain manual | Block `0x4aa54`: reads halfwords at `+0x0e`, `+0x10`, `+0x12` and `+0x14`. | The attempted `channel + red u32 + blue u32` helper is wrong and too short. Firmware expects four packed 16-bit fields; their meanings are unknown. The helper was removed. |
| `0x503` | Sensor test-pattern config | Block `0x4973c`: reads halfwords at `+0x0c` and `+0x0e`; log at `0xa8f51` reports the `+0x0e` field as the pattern. | The attempted `u32 channel; u32 pattern` put the menu value in the wrong halfword, so every selection actually requested pattern zero. The first halfword's meaning is unknown. |
| `0x506` | Sensor temperature get | Block `0x497a6`: the sensor returns a signed 16-bit value, sign-extended and stored as a word at `+0x0c`; log at `0xa8f21`. | `u32 channel; s32 temperature` is structurally correct. See "Sensor temperature" below: on this sensor the value is a constant sentinel, so there is no scale to establish. |
| `0xa07` | Scaler sharpness set | Block `0x48b68`: reads one byte at `+0x0c`; wrapper `0x563c4`; log at `0xa93e2`. | One `0..255` byte is structurally valid. A different opcode from the attempted V4L2 control. |
| `0xa09` | Sharpness set | Block `0x48b90`: reads one byte at `+0x0c`; wrapper `0x55548`. | The attempted control used this opcode and its value layout is structurally valid. Effect and preferred default need image-based validation. |
| `0xa0b` | Noise reduction set | Block `0x48baa`: reads one byte at `+0x0c`; wrapper `0x5e2b8`. | The one-byte-strength interpretation is structurally valid; effect and safe default are unvalidated. |
| `0xa0d` | Chroma suppression set | Block `0x48bc0`: reads three separate bytes at `+0x0c`, `+0x0d` and `+0x0e`; wrapper `0x555a0`; log at `0xa946c`. | A single V4L2 strength is not an honest representation. The attempted `u32 strength` happened to supply `{strength, 0, 0}`, but the meanings and valid combinations of all three fields are unknown. |
| `0xa19` | DRC set | Block `0x48f9c`: reads one byte at `+0x0c`; wrapper `0x56450`. | A one-byte value is structurally valid. Mapping it to `V4L2_CID_BACKLIGHT_COMPENSATION` is a policy guess, not firmware evidence. |

The small internal wrappers reinforce these widths: sharpness and DRC store a
single byte, chroma suppression three consecutive bytes, before submitting a
fixed-size internal message.

## Confirmed read-only command surface

The standard dispatcher's `0x2xx` jump table at `0x4826e` and the Apple-private
table at `0x7910` give a closed, non-exploratory GET list. The driver exposes
these as mode-`0400` debugfs files, readable only while channel zero is already
streaming:

| Opcode | Readback | Dispatcher evidence | Response after `u32 channel` |
|---|---|---|---|
| `0x203` | AE bias/tag | `0x499ec`, paired vtable GET for the `0x204` layout | `u16 bias; u16 reserved; u32 tag` |
| `0x207` | AE frame-rate maximum | `0x49a7c`, helper `0x470d8` | one `u32` |
| `0x209` | AE frame-rate minimum | `0x49ac2`, helper `0x470d8` | one `u32` |
| `0x20b` | AE gain cap | `0x49b06` | one `u32` |
| `0x20d` | AE integration-time maximum | `0x49b58` | one `u32` |
| `0x22a` | Sensor integration-time minimum | `0x49ede` | one computed `u32` |
| `0x22c` | Sensor integration-time maximum | `0x49f40` | one computed `u32` |
| `0x22d` | AE gain-cap minimum | `0x49f7c` | one `u32` |
| `0x22f` | AE gain-cap maximum with exposure | `0x49fbe` | one `u32` |
| `0x231` | AE gain-cap off value | `0x4a000` | one `u32` |
| `0x304` | AWB CCT | `0x4a7ae`, wrapper `0x9e464` | one `u32` |
| `0x30d` | AWB 2nd gain | `0x4a9b4` | three `u32` |
| `0x506` | Sensor temperature | `0x497a6` | signed 16-bit result, sign-extended to `s32` |
| `0x800` | Crop | `0x478a2` | eight `u32` — two rectangles |
| `0x8207` | Apple AE metering mode | `0x8e0a`, mappings at `0x9518`--`0x9522` | one `u8` (`0`--`3`) |

An on-demand read holds `ioctl_lock`, verifies `channel_running`, takes a
runtime-PM reference, sends exactly one compile-time-selected GET, and drops
the reference before unlocking. It cannot start an idle ISP, does not poll,
does not register hwmon, and offers no arbitrary-opcode input.

`0x203` and `0x20b` reach their responses through `0x4a722`, which is nothing
but `blx r2` on a function pointer from the channel context. Their widths are a
runtime vtable decision and are **not** recoverable from the dispatcher; the
layouts above rest on paired-setter reasoning.

The image-processing enum is misleading on this firmware: `0xa0a` sharpness
GET, `0xa0c` noise-reduction GET, `0xa0e` chroma-suppression GET and `0xa1a`
DRC GET all route to the unsupported-command block at `0x4996c`. Only the
adjacent setters are implemented. Those GET names are kept as recovered
protocol documentation but must not be sent, and the driver creates no debugfs
files for them.

## Complete dispatcher table sweep

The dispatcher is a binary-search compare tree over the opcode. It routes each
*dense* opcode class to its own `tbh [pc, rN, lsl #1]` table and handles sparse
or low opcodes by explicit comparison. Every table is guarded by the same range
check and the same default target — the unsupported-command block at `0x4996c`:

```text
subw  rN, r2, #<class base>
cmp   rN, #<count - 1>
bhi.w 0x4996c              ; unsupported
tbh   [pc, rN, lsl #1]     ; table base = this address + 4
```

Entries are little-endian halfwords; the target is `table_base + 2 * entry`. An
entry resolving to `0x4996c` is a command this firmware does **not** implement.
Scanning for `E8DF F0.x` and keeping the sites whose preamble branches to
`0x4996c` finds exactly twelve, and no thirteenth table shares that default:

| Table | Opcodes | Entries | Implemented | Unsupported |
|---|---|---:|---:|---:|
| `0x47644` | `0x104`--`0x126` | 35 | 34 | 1 |
| `0x48272` | `0x200`--`0x23a` | 59 | 50 | 9 |
| `0x4993a` | `0x300`--`0x311` | 18 | 13 | 5 |
| `0x4990a` | `0x400`--`0x40d` | 14 | 12 | 2 |
| `0x47fae` | `0x500`--`0x50c` | 13 | 13 | 0 |
| `0x47de6` | `0x602`--`0x608` | 7 | 7 | 0 |
| `0x47aa2` | `0x700`--`0x707` | 8 | 8 | 0 |
| `0x4788c` | `0x800`--`0x80a` | 11 | 11 | 0 |
| `0x4780c` | `0xa01`--`0xa2c` | 44 | 38 | 6 |
| `0x47746` | `0xb00`--`0xb05` | 6 | 6 | 0 |
| `0x47720` | `0xc00`--`0xc04` | 5 | 5 | 0 |
| `0x476e8` | `0xd00`--`0xd0d` | 14 | 14 | 0 |

234 opcodes, 211 implemented, 23 unsupported.

**Scope.** This settles only opcodes inside a table range. An opcode *outside*
every range is resolved by the compare tree and is not decided by the sweep —
`0x100` `CH_START` and `0x101` `CH_STOP` are outside every table and are
obviously implemented, since the driver starts a channel with them on every
stream. Do not read "absent from the tables" as "unsupported"; trace the tree.
Traced individually, `0xa00` `COLOR_SATURATION_GET` *is* unsupported: the tree
falls through to the `0x800` preamble at `0x4787e`, where `0xa00 - 0x800 =
0x200` exceeds the count and branches to `0x4996c`. The Apple `0x8xxx`/`0xcxxx`
commands the driver uses are likewise compare-tree cases, not table entries.

The method reproduces the hand-derived results in this file and agrees with
hardware. The four GETs found unsupported by hand (`0xa0a`, `0xa0c`, `0xa0e`,
`0xa1a`) come out unsupported. The ten standard-dispatcher GETs that were
identified before the sweep come out implemented at the exact handler addresses
already recorded for them — `0x499ec`, `0x49b06`, `0x49b58`, `0x49ede`,
`0x49f40`, `0x49f7c`, `0x49fbe`, `0x4a000`, `0x4a7ae` and `0x497a6` — fourteen
independent agreements. (`0x207`, `0x209`, `0x30d` and `0x800` are in the table
above because the sweep found them, so they corroborate nothing.) And of the 68
`CISP_CMD_*` opcodes `fthd_isp.c` sends, every one falling inside a table is
marked implemented, with zero contradictions. Those are commands that demonstrably work on the
MacBookAir7,2, so a table entry claiming otherwise would have falsified the
method.

### Unsupported on this firmware

These carry upstream names but reach `0x4996c`. Sending one gets an
unsupported-command response, so none is a candidate for anything:

`0x113` `RAW_FRAME_PROCESS_GO`; `0x210`/`0x211` AE noise-reduction control
param GET/SET; `0x213`/`0x214` AE pre-frame-rate GET/SET; `0x215`/`0x216` AE
red-eye param GET/SET; `0x21b` AE strobe param GET; `0x21d`/`0x21e` AE window
param GET/SET; `0x302`/`0x303` AWB window param GET/SET; `0x309`/`0x30a` AWB
CCM warmup matrix SET/GET; `0x30b` AWB 2nd-gain adaptive thresholds SET;
`0x408`/`0x409` AF window param GET/SET; `0xa02` tone-curve custom GET;
`0xa08` scaler sharpness GET; `0xa0a`, `0xa0c`, `0xa0e`, `0xa1a` as above.

Two consequences worth stating. AE and AWB metering-*window* configuration does
not exist on this firmware, so the spatial-weighting question the metering-mode
harness leaves open cannot be answered by programming a window — `0x8206` mode
selection is the only lever. And `0xa07` scaler sharpness joins
`0xa09`/`0xa0b`/`0xa0d`/`0xa19` as a setter with no readback: **every
image-processing setter this firmware implements is write-only**, so none can
be restored except by a firmware reload. Any future harness for them has to be
built around that.

### Implemented, with no driver readback

Implemented GET handlers the driver does not use. This is what rule 4 ("add GET
support first") can draw on; each still needs its response layout recovered.

| Opcode | Name | Handler |
|---|---|---|
| `0x105`/`0x106` | camera config current / camera config GET | `0x482f2` / `0x483a4` |
| `0x10d` | channel info GET | `0x4866a` |
| `0x119`/`0x11a` | camera MIPI freq current / MIPI frequency GET | `0x488f8` / `0x48916` |
| `0x11d` | ISO params GET | `0x48988` |
| `0x11e`/`0x11f` | camera pixel freq current / pixel frequency GET | `0x489ae` / `0x489cc` |
| `0x121` | camera error-count GET | `0x48a0c` |
| `0x205` | AE clip GET | `0x49a38` |
| `0x212` | AE param GET | `0x49bcc` |
| `0x217`/`0x219` | AE speed / AE stability GET | `0x49c1a` / `0x49c5e` |
| `0x223` | AE target GET | `0x49dc6` |
| `0x228` | AE stability-to-stable GET | `0x49e9e` |
| `0x236` | AE mode GET | `0x4a0ee` |
| `0x501` | sensor NVM GET | `0x49702` |
| `0x507`/`0x508` | per-module LSC info / LSC GET | `0x497d2` / `0x497f0` |
| `0x805`/`0x807`/`0x808` | colour calibration data / ideal / abs GET | `0x49360` / `0x493ca` / `0x49400` |
| `0xa22` | colour LSC table GET | `0x49110` |
| `0xb00` | output config GET | `0x47752` |

### Layouts recovered from the sweep

**`0x800` crop GET** (`0x478a2`) writes eight consecutive words — two
rectangles — straight out of the channel context:

```text
+0x0c..+0x18   ctx+0xd0, +0xd4, +0xd8, +0xdc
+0x1c..+0x28   ctx+0xb0, +0xb4, +0xb8, +0xbc
```

`CISP_CMD_CH_CROP_SET` sends one `(x, y, width, height)` rectangle, and the GET
returns two in the same form. The first group (`0xd0..0xdc`) echoes the
programmed crop; the second (`0xb0..0xbc`) is the full sensor array,
`0 0 1280 720` here. The GET only echoes what is in effect, so it cannot reveal
a silently adjusted rectangle. It confirms from the ISP side that a crop took
effect, and reads the array bounds without inferring them.

**`0x30d` AWB 2nd gain GET** (`0x4a9b4`) loads three destination pointers,
`+0x0c`, `+0x10` and `+0x14`, and calls a vtable entry at `ctx.obj+0x70`. Three
words of gain, not the two an R/B reading would predict, so the driver prints
them positionally and names no colour.

**`0x207`/`0x209` AE frame-rate maximum/minimum GET** (`0x49a7c`, `0x49ac2`)
share a helper at `0x470d8`, selected by its third argument (`1` maximum, `0`
minimum), and store a single `u32` at `+0x0c` (`0x49f74`, `0x4aad8`). Both
first test a channel-context field at `+0x98` against `0xffff` and take a
different, non-value path when it matches. Since `fthd_isp_cmd()` leaves the
caller's buffer alone in that case, an unwritten field reads back as the zero
the driver submitted: **a zero here means "firmware wrote nothing", not "zero
frames per second"**, and the debugfs file says so on the line. Neither handler
has been observed taking the sentinel path.

## Measured readback values

All from the MacBookAir7,2 under normal indoor conditions, sampled across
bright, dark, warm and cool scenes, after a runtime resume, at requested 30 and
15 fps, and after ten minutes of continuous streaming. Every run left the
stream live and produced no firmware, channel-stop, buffer, IOMMU or DMAR
fault.

| Readback | Value | Reading |
|---|---|---|
| Sensor temperature | `-1`, always | Unavailable sentinel; see below |
| AWB CCT | `2652` warm to `5777` cool, `4697`--`5301` ambient | Current CCT estimate in kelvin |
| AE bias / tag | `256` / `0`, invariant | Configuration, not live telemetry |
| AE gain cap / minimum | `8192` / `256`, invariant | Consistent with Q8.8 (`256` = 1x, `8192` = 32x); not proved |
| AE gain cap with exposure / off | `0` / `0` | Unknown |
| AE integration maximum | `33`, invariant including at requested 15 fps | A limit, not current exposure; unchanged by host-side decimation, as expected |
| Sensor integration minimum / maximum | `38` / `1000000` | Plausibly microseconds; not proved |
| AE metering mode | `3` | The mode the channel-start sequence programs |
| AE frame rate maximum / minimum | `7672` / `7672` | 29.97 fps in Q8.8; see below |
| AWB 2nd gain | `4096 4096 4096` | Manual stage at unity; see below |
| Crop | active crop / `0 0 1280 720` | See `0x800` above |

**AWB CCT is the one value with an established meaning.** Warm-to-cool light
moving it from `2652` to `5777`, with the right ordering and realistic
magnitudes, while bias, gain caps and integration limits stayed put, is strong
evidence for a current correlated-colour-temperature estimate in kelvin. A dark
frame has no useful illuminant to describe, so a reading there is not evidence
against it. This is what justifies exposing it as the read-only
`awb_cct_estimate` V4L2 control; cross-model confirmation is still open, which
is why the CID is driver-private.

**The frame-rate window is Q8.8 fps, and the sensor follows it.** At 30 fps
both bounds read `7672`: `7672 / 256` is `29.96875`, the NTSC `30000/1001`
truncated in Q8.8 and the rate measured at the stream. A 15 fps request reads
back `3840`/`3840` and delivers 15.00 fps, and with exposure priority the
minimum reads `1280` (5 fps) and dim light slows the stream below 30. The Q8.8
encoding is therefore corroborated on a quantity measured directly.

**AWB second gain is not a live measurement.** All three words read exactly
`4096` while the CCT estimate reported `2785` — markedly warm light, in which a
live white-balance gain triple cannot be equal on all three channels. It is
most plausibly unity in a fixed-point format where `4096` is `1.0`, left at its
default, and the sweep supports that: `0x30c` 2nd-gain *manual* is implemented
while `0x30b` its adaptive thresholds is not, which describes a manual-only
stage nothing is driving. Unlike AWB CCT there is no evidence it measures
anything, so it stays a debugfs readback with no CID.

**Sensor temperature is closed on this sensor.** `-1` came back cold after
boot, after ten minutes of continuous streaming, and under bright, dark, warm
and cool light. A physical scale, however unknown, would have moved with die
temperature over that stream, so this is a not-supported sentinel and there is
nothing to calibrate. The driver names it `FTHD_SENSOR_TEMPERATURE_NONE` and
prints `-1 (unavailable)`, raw value first so parsers keep working. hwmon
registration would be wrong even on a sensor that returns something else: that
ABI requires millidegrees Celsius and no reading here establishes a unit.

## Test scaffolding

Neither harness below is a V4L2 ABI. Nothing they touch is registered as a
control or replayed at `STREAMON`, module load or resume. Remove them, or keep
them debug-only, once the command semantics are established.

### Same-value setters

Five root-write-only debugfs nodes cover AE bias/tag (`0x204`), metering mode
(`0x8206`), AE integration maximum (`0x20e`), gain cap (`0x20c`) and minimum
gain cap (`0x22e`). They accept no numeric input — the only valid write is
`same`. Under `ioctl_lock` and an active-stream check the kernel performs GET,
SET of the exact returned value, GET and equality verification, so userspace
cannot choose an out-of-range value or make two gain limits cross.

`tests/hw-validate.sh --only roundtrips` persists an armed marker before each
write, uses a new live stream per command, checks capture after `STREAMOFF`,
cycles runtime PM and scans for firmware/DMA faults. `ROUNDTRIPS` restricts a
run to one name, so validation stays one setter per run.

All five passed individually: GET/SET/GET matched, the stream stayed alive,
capture succeeded after restart and after a runtime-PM idle cycle, and no
firmware, channel-stop, IOMMU or DMAR fault appeared. That validates each
recovered setter's payload width and its ability to accept firmware's own
current value. It establishes **no** unit, range, visible effect, safe
non-current value or correct multi-command manual-exposure sequence, and does
not justify V4L2 exposure or replay.

### Bounded metering-mode semantics

Metering is the first non-current-value experiment, because disassembly closes
its domain to four values (`0`--`3`), mode `3` is already programmed by the
established channel-start sequence, and its current-value setter passed the
round-trip test. The `test_ae_metering_mode` node accepts only the tokens
`mode0`--`mode3`, rejects numeric parsing, requires a running channel, holds
`ioctl_lock` and a runtime-PM reference, and fails unless firmware returns
exactly the requested mode.

The opt-in `metering-modes` section starts a fresh stream per mode, persists an
armed marker, discards 120 frames for AE settling, retains 12 packed-YUV
frames, and reports full-frame, central-spot, centre-quarter and outer-region
mean luma. The operator supplies a fixed high-contrast scene with a bright
central target; the mode-3 baseline must measure the spot at least 20 luma
above the outer region without clipping, or the run stops before the other
modes. Before `STREAMOFF` it writes and verifies the original mode, then checks
a fresh capture, a runtime-PM idle/resume capture, and the fault logs. An EXIT
trap attempts the same restore if the runner is interrupted, and independently
of that every new channel starts in established mode `3`.

**Result: accepted and persistent, but not visibly distinct.** On a controlled
scene meeting the precondition (mode 3 spot/outer `99.8/40.0`), all four modes
read back exactly, restored to `3`, survived restart and runtime PM, and stayed
fault-free — but the largest cross-mode spreads were `1.2` full-frame, `0.7`
spot, `0.6` centre-quarter and `1.5` outer luma, compatible with capture noise
or small scene drift.

| Mode | Full | Central spot | Centre quarter | Outer |
|---:|---:|---:|---:|---:|
| `3` | `40.2` | `99.8` | `40.9` | `40.0` |
| `0` | `40.0` | `99.1` | `40.3` | `39.9` |
| `1` | `41.2` | `99.6` | `40.7` | `41.4` |
| `2` | `40.2` | `99.4` | `40.4` | `40.1` |

That is not enough to map the firmware values onto the standard V4L2 average,
centre-weighted, spot and matrix names, and the menu is not registered.

Because the normal channel sequence programs metering *before* AE starts while
the node above mutates it with AE already running,
`test_ae_metering_mode_restart` performs AE STOP, metering SET, AE START and an
exact GET under the same boundaries. `METERING_RESTART_AE=1` selects it in the
runner. AE start/stop is an existing hardware-tested V4L2 path.

## Semi-planar output: NV12, not NV16

Output-format code 0 is not new: it existed in the upstream driver in 2015,
where a comment described it only as "plane 0 Y plane 1 UV". Upstream commit
`d57b16fc6438` disabled it for missing multiplanar support and it is still
disabled in `364b1c663583`. The old code modelled it as two vb2 planes while
using the single-planar `V4L2_BUF_TYPE_VIDEO_CAPTURE` API and reported only
`width * height` bytes per plane.

Nothing in that comment gave the format a chroma sampling. Every later reading
— upstream's, this fork's, and an earlier revision of this file — supplied
4:2:2 from the assumed name and called it NV16. **Hardware says 4:2:0.**
Capturing through code 0 and mapping the frame row by row:

| Region | Bytes | Content |
|---|---:|---|
| rows 0-719 | 921,600 | luma, complete |
| rows 720-1079 | 460,800 | chroma, mean 128.3 |
| rows 1080-1439 | 460,800 | never written, all zero |

360 chroma rows for a 720-row frame is 4:2:0. Split into components the chroma
gives Cb 122.3 / Cr 135.3 against Cb 122.5 / Cr 135.4 from a YUYV capture of
the same scene seconds later; luma agrees at 93.1 against 92.9. The correct
single-planar layout is therefore:

```text
bytesperline = width
sizeimage    = width * height * 3 / 2
ISP addr0    = mapped buffer base
ISP addr1    = mapped buffer base + width * height
```

The driver's IOMMU allocator gives the scatterlist one contiguous ISP
virtual-address range, so the chroma plane needs no mapping of its own. NV12 is
advertised on that evidence, and - once it had streamed at the 4:2:0 sizeimage
without a blank row or a fault - made the default format, enumerated first, on
the grounds that it is three quarters the bytes and that index 0 is read mostly
by code feeding a display or a 4:2:0 encoder. NV16 is not offered, because no
output-format code produces it.

**Whether code 0 is the pipeline's native sampling is still open.** Everything
above measures what the ISP *wrote*; none of it distinguishes a natively 4:2:0
pipeline from a 4:2:2 one downsampling on the way out. The chroma agreement
with YUYV is between *means*, which are identical under either. Deciding it
needs a scene with fine horizontal chroma structure captured in both formats,
comparing chroma row against chroma row: identical adjacent rows in the YUYV
capture would mean the packed format is upsampling something already 4:2:0,
while crisply differing rows would mean NV12 is a real downsample.

The intuition that guessing 4:2:0 was the dangerous direction — sizing a
buffer at 1.5 bytes per pixel while the ISP wrote 2 would overrun the mapping —
has the risk backwards, and is worth knowing because it is the natural one to
reach for. The error ran the other way: sizing for 4:2:2 over-allocated and
left a tail unwritten, which cannot overrun anything.

**`x2` in `CISP_CMD_CH_OUTPUT_CONFIG_SET` is the destination row stride in
bytes**, not the "chroma size?" upstream guessed. Upstream hardcoded `width *
2`, which for the packed formats is simultaneously a correct stride and an
unremarkable constant, so nothing distinguished the two readings until a
one-byte-per-pixel plane arrived: hardware then wrote luma rows 2560 bytes
apart into a buffer laid out for 1280, leaving exactly 50% of the luma rows
zero in a strict every-other-row pattern. No IOMMU fault occurred, because
`sizeimage` still covered everything written — the ISP skips rows rather than
overrunning, so the predicted "bounded, loud" failure was in fact silent. The
driver now passes `bytesperline`, leaving the packed formats byte-for-byte
unchanged.

Two testing lessons are built into `tests/hw-validate.sh --only nv12` as a
result. An earlier hardware report recorded a pass that validated nothing: the
format was absent from `ENUM_FMT`, `S_FMT` silently coerced the fourcc to YUYV,
both formats had the same total byte count, and the test checked only size and
capture. The section now re-reads `G_FMT` and requires the fourcc to survive,
checks `bytesperline` and `sizeimage`, counts blank luma rows, inspects the
planes separately at their 4:2:0 extents, and compares chroma against a YUYV
capture of the same scene rather than an absolute threshold. The same trap
caught the crop harness, which judged channel health by `v4l2-ctl`'s exit
status — and `v4l2-ctl` exits 0 when `VIDIOC_STREAMON` fails. **An exit status
is not evidence that a capture happened.**

## Rules for any reimplementation

1. Never register a control whose defaults cause an unvalidated opcode to be
   sent by ordinary `STREAMON` or runtime-resume replay.
2. Match every field width, offset and total payload length to firmware
   evidence. Zero-initialise reserved fields explicitly.
3. Do not invent units, ranges, or a standard V4L2 meaning from an opcode name.
4. Add GET support first where possible; it reveals current firmware values and
   valid structure widths without changing image state.
5. Validate one setter at a time, only after a normal stream is stable. Sync
   storage first and preserve a one-boot module-blacklist recovery path. A
   same-value pass validates framing, not the command's unit or safe range.
6. A successful ioctl is not enough. Read the value back, inspect the firmware
   log, capture frames, measure the intended image effect, stop and restart the
   stream, and check for delayed faults.
7. Do not expose sensor temperature through hwmon until its scale is
   established. On this sensor there is nothing to establish — the value is a
   constant sentinel.
8. Do not advertise a pixel format until `G_FMT` confirms the fourcc survives
   and captured luma and chroma plane contents are both plausible at the sizing
   being claimed. Implementing it behind a default-off module parameter is not
   the same as advertising it, and is what makes the test runnable. NV12
   completed that path; NV16 never will.
9. A recovered value may reach V4L2 as a **read-only** control once its meaning
   is supported by hardware evidence. `v4l2_ctrl_handler_setup()` skips
   read-only controls, so such a control cannot replay a firmware SET — the
   mechanism behind the lockups, and the reason rule 1 exists.
   `FTHD_CID_AWB_CCT_ESTIMATE` is the first. Use a driver-private CID unless
   the standard control means exactly the same thing; a measurement published
   under a CID that means a set point is a wrong answer with a familiar name.

## Open questions

- AE-bias encoding, units, valid range and tag semantics.
- The AWB-CCT manual setter's second word. The GET value tracks kelvin here and
  is published as the read-only `awb_cct_estimate` control; what remains open
  is cross-model confirmation of the unit, and the second word — which is why
  there is a readback and no way to write one.
- The four packed fields used by AWB first-gain manual.
- The first halfword and supported pattern indices for sensor test pattern.
- Integration-time and gain units and ranges, and the correct atomic
  manual-exposure sequence. The sweep confirms `0x22b` AE manual-mode set and
  `0x236` AE mode get are both implemented, so that alternative to collapsing
  two gain caps is real rather than hypothetical; neither payload has been
  recovered.
- Meanings and safe combinations of the three chroma-suppression bytes.
- Whether AE metering modes `0`--`3` are visibly distinct on any machine.
  Accepted, persistent and teardown-safe here, but not measurably different.
- Whether any sensor other than this one returns something other than the `-1`
  temperature sentinel, and its scale if so.
- Per-frame spacing under decimation. The mean rate is measured and correct at
  every divisor, but `hw-validate.sh` checks only a coarse bunching floor, so
  uneven spacing at the right average would still pass.
