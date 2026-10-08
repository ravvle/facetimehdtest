#!/usr/bin/env bash
#
# Validate the downstream changes that only a real MacBook can confirm.
#
# tests/smoke-capture.sh answers "does the camera work at all". This script
# answers the open questions in src/facetimehd/DOWNSTREAM.md under "Hardware
# validation status" - the ones a compiler, shellcheck and CI are all
# structurally unable to reach. Each section below names the item it is
# testing so a result can be pasted straight back into that document.
#
#   sudo ./tests/hw-validate.sh                 # everything except --reboot
#   sudo ./tests/hw-validate.sh --only probe,timing
#   sudo ./tests/hw-validate.sh --skip suspend  # laptop in use, or headless
#   sudo ./tests/hw-validate.sh --reboot        # arm the shutdown-path test
#
# Needs v4l-utils. The suspend section asks you to close and open the lid, so
# it needs a terminal and someone at the machine; --skip suspend drops it.
# The report is written to a file and printed at the end; attach it to a bug.
#
# This is destructive in the sense that it loads and unloads the module,
# suspends the machine, and (with --reboot) reboots it. It changes no
# persistent configuration.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"

MODULE_NAME=facetimehd
STATE_DIR=/var/lib/facetimehd
REBOOT_STATE="$STATE_DIR/hw-validate-reboot"
REPORT="${REPORT:-/tmp/facetimehd-hw-validate-$(date +%Y%m%d-%H%M%S).log}"

# Must exceed FTHD_AUTOSUSPEND_DELAY_MS (5000) in fthd_drv.c by enough that a
# loaded machine still parks the device before we look. Read from sysfs at run
# time where possible; this is only the fallback.
IDLE_WAIT="${IDLE_WAIT:-9}"
FRAMES="${FRAMES:-30}"
SUSPEND_SECS="${SUSPEND_SECS:-20}"
LID_TIMEOUT="${LID_TIMEOUT:-180}"
DEVICE="${DEVICE:-}"
PROFILE_SETTLE_SECS="${PROFILE_SETTLE_SECS:-5}"
PROFILE_WARMUP_SECS="${PROFILE_WARMUP_SECS:-600}"
ROUNDTRIPS="${ROUNDTRIPS:-ae_bias ae_metering_mode ae_integration_time_max ae_gain_cap ae_gain_cap_min}"
METERING_SETTLE_FRAMES="${METERING_SETTLE_FRAMES:-120}"
METERING_CAPTURE_FRAMES="${METERING_CAPTURE_FRAMES:-12}"
METERING_WAIT_SECS="${METERING_WAIT_SECS:-8}"
METERING_RESTART_AE="${METERING_RESTART_AE:-0}"
METERING_RESTORE_NODE=""
METERING_ORIGINAL=""
# Requested rates. S_PARM programs the ISP's AE frame-rate window, which
# accepts 2-30 fps, so 2 fps is the slowest stream the driver can produce.
FRAMERATE_RATES="${FRAMERATE_RATES:-30 15 10 5 2}"
FRAMERATE_SECS="${FRAMERATE_SECS:-6}"
FRAMERATE_TOLERANCE="${FRAMERATE_TOLERANCE:-12}"
FRAMERATE_OFF_SECS="${FRAMERATE_OFF_SECS:-5}"
CROP_WIDTH="${CROP_WIDTH:-640}"
CROP_HEIGHT="${CROP_HEIGHT:-360}"
NV12_FRAMES="${NV12_FRAMES:-10}"

# Removed inferred controls are intentionally not selectable here. Readbacks
# are in the normal suite after their first complete fault-free run. Frame
# rate and crop use hardware-tested commands, so they run by default; profiling, same-value setter round trips, metering semantics and the
# still-unadvertised NV16 format remain explicit hardware work.
DEFAULT_SECTIONS="probe timing controls framerate crop nv12 runtimepm suspend wedged readbacks"
ALL_SECTIONS="$DEFAULT_SECTIONS readback-profile roundtrips metering-modes crop-geometry"
SECTIONS="$DEFAULT_SECTIONS"
DO_REBOOT=0
INTERACTIVE=1
[ -t 0 ] || INTERACTIVE=0

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

      --only LIST    Run only these sections (comma-separated).
      --skip LIST    Run everything except these sections.
      --reboot       Arm the reboot-while-streaming test. Streams, then reboots
                     the machine. Re-run this script after the reboot to read
                     the verdict. Not included in a default run.
      --no-interactive
                     Skip everything that needs a person: covering the camera
                     for the exposure tests, and the lid prompt for suspend.
  -h, --help         Show this help.

Sections: $ALL_SECTIONS
  readback-profile, roundtrips and metering-modes are opt-in hardware
  experiments.

Environment:
  DEVICE        Video node to test (default: the node $MODULE_NAME claims).
  FRAMES        Frames per capture (default: 30).
  IDLE_WAIT     Seconds to wait for runtime suspend (default: 9).
  SUSPEND_SECS  Seconds to ask you to keep the lid closed (default: 20).
  LID_TIMEOUT   Seconds to wait for the lid before giving up (default: 180).
  PROFILE_SETTLE_SECS
                Seconds to let AE/AWB settle per profile phase (default: 5).
  PROFILE_WARMUP_SECS
                Streaming warm-up before the final temperature read (default: 600).
  ROUNDTRIPS    Space-separated same-value setters to test. Default:
                ae_bias ae_metering_mode ae_integration_time_max
                ae_gain_cap ae_gain_cap_min
  METERING_SETTLE_FRAMES
                Frames discarded after each metering change (default: 120).
  METERING_CAPTURE_FRAMES
                Frames retained for each metering mode (default: 12).
  METERING_WAIT_SECS
                Seconds before checking each bounded capture (default: 8).
  METERING_RESTART_AE
                Set to 1 to stop/restart AE around each mode change (default: 0).
  FRAMERATE_RATES
                Requested frame rates to verify (default: 30 15 10 5 2).
  FRAMERATE_SECS
                Seconds of steady-state capture per rate (default: 6).
  FRAMERATE_TOLERANCE
                Percent the measured rate may differ by (default: 12).
  FRAMERATE_OFF_SECS
                Seconds to stream before the mid-stream STREAMOFF (default: 5).
  CROP_WIDTH / CROP_HEIGHT
                Output size used while moving the crop (default: 640x360).
  NV12_FRAMES   Frames captured for the NV12 plane check (default: 10).
  REPORT        Report path (default: /tmp/facetimehd-hw-validate-DATE.log).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --only) shift; [ $# -gt 0 ] || die "--only needs a list"
                SECTIONS="${1//,/ }" ;;
        --skip) shift; [ $# -gt 0 ] || die "--skip needs a list"
                for _s in ${1//,/ }; do
                    SECTIONS="${SECTIONS//$_s/}"
                done ;;
        --reboot)         DO_REBOOT=1 ;;
        --no-interactive) INTERACTIVE=0 ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage >&2; die "Unknown argument: $1" ;;
    esac
    shift
done

for _s in $SECTIONS; do
    case " $ALL_SECTIONS " in
        *" $_s "*) ;;
        *) die "Unknown section: $_s (valid: $ALL_SECTIONS)" ;;
    esac
done

for _numeric_name in METERING_SETTLE_FRAMES METERING_CAPTURE_FRAMES \
                     METERING_WAIT_SECS FRAMERATE_SECS FRAMERATE_TOLERANCE \
                     FRAMERATE_OFF_SECS CROP_WIDTH CROP_HEIGHT NV12_FRAMES; do
    _numeric_value="${!_numeric_name}"
    case "$_numeric_value" in
        ''|*[!0-9]*|0) die "$_numeric_name must be a positive integer" ;;
    esac
done

for _rate in $FRAMERATE_RATES; do
    case "$_rate" in
        ''|*[!0-9]*|0|1) die "FRAMERATE_RATES must be integers from 2 to 30" ;;
    esac
done

case "$METERING_RESTART_AE" in
    0|1) ;;
    *) die "METERING_RESTART_AE must be 0 or 1" ;;
esac

wants() { case " $SECTIONS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

require_root
require_cmds v4l2-ctl modprobe
has_facetimehd_hardware ||
    die "No FaceTime HD camera (14e4:1570) on this machine - nothing to test."

# ---------------------------------------------------------------- reporting --

# Every result is one line so the summary can be pasted into a bug report and
# still be read by a human. Status is one of PASS/FAIL/WARN/INFO/SKIP; FAIL is
# the only one that changes the exit code.
RESULTS=()
FAILED=0

result() {
    local status="$1" id="$2" msg="$3"
    RESULTS+=("$status|$id|$msg")
    case "$status" in
        PASS) ok   "[$id] $msg" ;;
        FAIL) bad  "[$id] $msg"; FAILED=1 ;;
        WARN) warn "[$id] $msg" ;;
        SKIP) info "[$id] skipped: $msg" ;;
        *)    info "[$id] $msg" ;;
    esac
    printf '%s|%s|%s\n' "$status" "$id" "$msg" >>"$REPORT.results"
}

log() { printf '%s\n' "$*" >>"$REPORT"; }

log_section() {
    log ""
    log "=============================================================="
    log "$*"
    log "=============================================================="
}

# dmesg cursors.
#
# Counting lines does not work here. This driver logs its whole DDR/PLL
# bring-up at dev_info level on *every* runtime-PM resume, which happens every
# few idle seconds, so the kernel ring buffer wraps within a minute or two on a
# normal run. Once it wraps, `dmesg | wc -l` stops growing and a
# `tail -n +$cursor` returns nothing at all - which silently turns "I found no
# PM records" into "the machine never suspended". That misdiagnosis is exactly
# what this replaces.
#
# Write a unique token into the log instead and read back everything after its
# last occurrence. If the token itself has been evicted we fall back to
# returning the whole buffer and say so: over-reporting is recoverable, an
# empty result that reads as a verdict is not.
DMESG_TOKEN=""
DMESG_CURSOR=0
DMESG_WRAPPED=0

dmesg_mark() {
    if [ -w /dev/kmsg ]; then
        DMESG_TOKEN="hw-validate-mark-$$-${EPOCHSECONDS:-$(date +%s)}-$RANDOM"
        if printf '%s\n' "$DMESG_TOKEN" >/dev/kmsg 2>/dev/null; then
            return 0
        fi
    fi
    DMESG_TOKEN=""
    DMESG_CURSOR="$(dmesg 2>/dev/null | wc -l)"
}

dmesg_since() {
    if [ -n "$DMESG_TOKEN" ]; then
        dmesg 2>/dev/null | awk -v tok="$DMESG_TOKEN" '
            { lines[NR] = $0; if (index($0, tok)) last = NR }
            END {
                if (last == 0) { print "HW-VALIDATE-RING-WRAPPED" }
                for (i = last + 1; i <= NR; i++) print lines[i]
            }'
    else
        dmesg 2>/dev/null | tail -n "+$((DMESG_CURSOR + 1))"
    fi
}

dmesg_driver() { dmesg_since | grep -i "$MODULE_NAME\|fthd" || true; }

# Call after any dmesg_since whose emptiness would be read as a result.
check_ring_wrap() {
    if dmesg_since | grep -q HW-VALIDATE-RING-WRAPPED; then
        DMESG_WRAPPED=1
        return 0
    fi
    return 1
}

# --------------------------------------------------------------- primitives --

pci_slot() {
    local d vendor device
    for d in /sys/bus/pci/devices/*; do
        # Written as a negated if rather than 'A && B || continue': that reads
        # as if-then-else but is not one, and the pattern is worth avoiding even
        # where, as here, it happens to behave correctly.
        if [ ! -r "$d/vendor" ] || [ ! -r "$d/device" ]; then
            continue
        fi
        read -r vendor <"$d/vendor"
        read -r device <"$d/device"
        if [ "$vendor" = 0x14e4 ] && [ "$device" = 0x1570 ]; then
            basename "$d"
            return 0
        fi
    done
    return 1
}

SLOT="$(pci_slot || true)"
PCI_DIR="${SLOT:+/sys/bus/pci/devices/$SLOT}"

runtime_status() {
    [ -n "$PCI_DIR" ] && [ -r "$PCI_DIR/power/runtime_status" ] || return 1
    cat "$PCI_DIR/power/runtime_status"
}

find_device() {
    local node name
    for node in /dev/video*; do
        [ -e "$node" ] || continue
        name="$(v4l2-ctl --device "$node" --info 2>/dev/null |
                sed -n 's/^[[:space:]]*Driver name[[:space:]]*:[[:space:]]*//p')"
        if [ "$name" = "$MODULE_NAME" ]; then
            printf '%s\n' "$node"
            return 0
        fi
    done
    return 1
}

wait_for_device() {
    local _
    for _ in $(seq 1 20); do
        DEVICE="$(find_device || true)"
        [ -n "$DEVICE" ] && return 0
        sleep 0.5
    done
    return 1
}

# Every capture in this script is bounded, because a stream that produces no
# buffers at all is a real observed failure and not a hypothetical one: an early
# run of the crop section met a rectangle the ISP accepted and then never
# delivered a frame for, and v4l2-ctl sat in vb2_wait_for_done_vb indefinitely.
# Unbounded, that wedges the whole run rather than failing one check.
#
# The bound has to scale with the frame count and the requested rate. Anything
# fixed either kills a legitimately slow capture - ten frames at 2 fps
# is five seconds of correct behaviour - or leaves a starved 30 fps stream
# hanging for minutes. The slack covers open, REQBUFS, and a runtime-PM resume
# with its DDR retrain and firmware reload.
CAPTURE_SLACK_SECS="${CAPTURE_SLACK_SECS:-20}"

capture_timeout_secs() {
    awk -v n="$1" -v r="${2:-30}" -v slack="$CAPTURE_SLACK_SECS" \
        'BEGIN{ if (r <= 0) r = 30; printf "%d", n / r + slack }'
}

# Exit status 124 means the stream starved; callers that can say something
# useful about that distinguish it, and the rest correctly see a failure.
capture_ok() {
    local frames="${1:-$FRAMES}" rate="${2:-30}"
    timeout -s TERM "$(capture_timeout_secs "$frames" "$rate")" \
        v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count="$frames" \
                 --stream-to=/dev/null >>"$REPORT" 2>&1
}

# Ask for a packed format before parsing pixels out of a capture. NV12 is the
# driver's default, so a capture nobody has configured is now semi-planar and
# every "byte 0 of each pair is Y" parser below would read chroma as luma. It
# is done per capture rather than once per run because reloading the module -
# which the timing, runtimepm and suspend sections all do - puts the device
# back on its default. Width and height are left out deliberately: v4l2-ctl
# fills the unmentioned fields from the current format, so whatever geometry a
# section has set up survives.
use_packed_format() {
    v4l2-ctl --device "$DEVICE" --set-fmt-video=pixelformat=YUYV \
        >/dev/null 2>&1
}

# Mean luma of one frame, sampled across the whole image rather than the head
# of the file. Taking the first 200KB of a 1280-wide YUYV frame only covers
# the top ~78 rows, so a hand entering the bottom of the shot, or a ceiling
# light in the top strip, skews the number badly - and this is the measurement
# the auto-exposure verdict rests on. Six chunks spread through the frame cost
# the same and actually represent it.
#
# Assumes a packed YUV format where byte 0 of each pair is Y, so it asks for
# one first; this is a relative comparison anyway.
mean_luma() {
    local tmp size chunk i off
    use_packed_format || return 1
    tmp="$(mktemp)"
    if ! v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=1 \
                  --stream-to="$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"; return 1
    fi
    size="$(stat -c %s "$tmp" 2>/dev/null || echo 0)"
    if [ "$size" -lt 12000 ]; then
        rm -f "$tmp"; return 1
    fi
    chunk=$(( size / 6 ))
    for i in 0 1 2 3 4 5; do
        off=$(( i * chunk ))
        dd if="$tmp" bs=1 skip="$off" count=10000 status=none 2>/dev/null
    done | od -An -tu1 -v |
        awk '{for(i=1;i<=NF;i+=2){s+=$i;n++}} END{if(n)printf "%.1f\n",s/n; else print "0"}'
    rm -f "$tmp"
}

# Full-frame, central spot, centre-quarter and outer-region means from the last
# complete packed-YUV frame in a multi-frame capture. Y occupies every even
# byte in YUYV. The smaller spot verifies that the operator's
# bright target is actually where the metering experiment expects it.
frame_luma_metrics() {
    local file="$1" frame_size="$2" width="$3" height="$4"
    local size complete

    size="$(stat -c %s "$file" 2>/dev/null || echo 0)"
    complete=$(( size / frame_size ))
    [ "$complete" -gt 0 ] || return 1

    dd if="$file" bs="$frame_size" skip=$(( complete - 1 )) count=1 \
       status=none 2>/dev/null |
        od -An -tu1 -v |
        awk -v w="$width" -v h="$height" '
            {
                for (i = 1; i <= NF; i++) {
                    value = $i
                    if (byte % 2 == 0) {
                        pixel = byte / 2
                        x = pixel % w
                        y = int(pixel / w)
                        full += value
                        full_n++
                        if (x >= int(3 * w / 8) && x < int(5 * w / 8) &&
                            y >= int(3 * h / 8) && y < int(5 * h / 8)) {
                            spot += value
                            spot_n++
                        }
                        if (x >= int(w / 4) && x < int(3 * w / 4) &&
                            y >= int(h / 4) && y < int(3 * h / 4)) {
                            centre += value
                            centre_n++
                        } else {
                            outer += value
                            outer_n++
                        }
                    }
                    byte++
                }
            }
            END {
                if (!full_n || !spot_n || !centre_n || !outer_n)
                    exit 1
                printf "full=%.1f spot=%.1f centre=%.1f outer=%.1f", \
                       full / full_n, spot / spot_n, \
                       centre / centre_n, outer / outer_n
            }'
}

# The evidence that a stream tore down cleanly. Absence of all of these is what
# earlier runs got wrong: a viewer that visibly kept producing frames was
# reported as a pass while the log recorded a failed channel stop and four DMA
# writes to unmapped address zero.
FAULT_PATTERN='firmware stopped responding|failed to stop firmware channel|unknown tag|invalid state|IOMMU.*fault|DMAR:.*fault|channel stop failed'

faults_present() { dmesg_since | grep -Eqi "$FAULT_PATTERN"; }

# Milliseconds since the epoch.
#
# Deliberately not `date +%s%3N`. Ubuntu 26.04 ships uutils coreutils, whose
# date ignores the %3N field-width modifier and prints all nine nanosecond
# digits, so that expression yields an 18-digit number and every duration
# derived from it is garbage - silently, and on a distribution this project
# supports. Bash's own EPOCHREALTIME has no such ambiguity. Its decimal
# separator follows the locale, hence the substitution.
now_ms() {
    local t="${EPOCHREALTIME:-}"

    if [ -n "$t" ]; then
        t="${t/,/.}"
        # 10# so a fractional part with leading zeros is not read as octal.
        printf '%s\n' "$(( ${t%.*} * 1000 + 10#${t#*.} / 1000 ))"
        return 0
    fi

    # Second resolution: enough to catch a wildly wrong rate, not enough to
    # confirm a correct one. clock_sane() below is what decides whether the
    # measurements that depend on this are reported at all.
    printf '%s\n' "$(( $(date +%s) * 1000 ))"
}

# A rate measurement is only as good as its clock, and the failure above was
# silent - it produced confident, wrong frame rates rather than an error. So the
# clock is checked against a known interval before any rate is trusted.
clock_sane() {
    local before after elapsed
    before="$(now_ms)"
    sleep 0.5
    after="$(now_ms)"
    elapsed=$(( after - before ))
    [ "$elapsed" -ge 300 ] && [ "$elapsed" -le 3000 ]
}

# Capture @1 frames at an expected rate of @2 and print how many milliseconds it
# took. Non-zero exit means the capture failed rather than merely ran slowly -
# 124 specifically means it starved - which the caller must distinguish, because
# a timing measurement taken from a killed capture is not a measurement.
timed_capture() {
    local frames="$1" rate="${2:-30}" start end rc
    start="$(now_ms)"
    timeout -s TERM "$(capture_timeout_secs "$frames" "$rate")" \
        v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count="$frames" \
                 --stream-to=/dev/null >>"$REPORT" 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    end="$(now_ms)"
    printf '%s\n' "$(( end - start ))"
}

# Sixteen block means (a 4x4 grid) of the last complete packed-YUV frame in a
# capture. Y is every even byte in YUYV. Two such signatures
# taken of the same still scene through different crop rectangles are how this
# script tells "the ISP moved the window" from "the ISP ignored the origin", which
# a single full-frame mean cannot do.
packed_block_luma() {
    local file="$1" frame_size="$2" width="$3" height="$4"
    local size complete

    size="$(stat -c %s "$file" 2>/dev/null || echo 0)"
    complete=$(( size / frame_size ))
    [ "$complete" -gt 0 ] || return 1

    dd if="$file" bs="$frame_size" skip=$(( complete - 1 )) count=1 \
       status=none 2>/dev/null |
        od -An -tu1 -v |
        awk -v w="$width" -v h="$height" '
            {
                for (i = 1; i <= NF; i++) {
                    if (byte % 2 == 0) {
                        pixel = byte / 2
                        bx = int((pixel % w) * 4 / w)
                        by = int(int(pixel / w) * 4 / h)
                        if (bx > 3) bx = 3
                        if (by > 3) by = 3
                        b = by * 4 + bx
                        sum[b] += $i
                        n[b]++
                    }
                    byte++
                }
            }
            END {
                for (b = 0; b < 16; b++) {
                    if (!n[b])
                        exit 1
                    out = out sprintf("%s%.1f", (b ? " " : ""), sum[b] / n[b])
                }
                print out
            }'
}

# How differently two block signatures are *shaped*, with each one's own mean
# removed first. Auto-exposure re-converges between two captures and shifts the
# whole frame, so a raw difference would report a change the crop did not make;
# subtracting the mean leaves only where the light is, which is what moving the
# rectangle actually changes.
block_shape_diff() {
    awk -v a="$1" -v b="$2" '
        BEGIN {
            na = split(a, A, " ")
            nb = split(b, B, " ")
            if (na != nb || na == 0)
                exit 1
            for (i = 1; i <= na; i++) {
                ma += A[i]
                mb += B[i]
            }
            ma /= na
            mb /= nb
            for (i = 1; i <= na; i++) {
                d = (A[i] - ma) - (B[i] - mb)
                if (d < 0)
                    d = -d
                s += d
            }
            printf "%.1f\n", s / na
        }'
}

# Spread of one signature: a scene with no spatial structure cannot show that
# the crop moved, whatever the driver does.
block_spread() {
    awk -v a="$1" '
        BEGIN {
            n = split(a, A, " ")
            if (n == 0)
                exit 1
            min = max = A[1]
            for (i = 1; i <= n; i++) {
                if (A[i] < min) min = A[i]
                if (A[i] > max) max = A[i]
            }
            printf "%.1f\n", max - min
        }'
}

# What fraction of a plane's rows are entirely zero, as a percentage.
#
# This is the single most diagnostic NV16 measurement, and it is the one the
# first hardware run did not have. A destination row stride that disagrees with
# the buffer layout makes the ISP skip rows rather than overrun anything, so it
# raises no IOMMU fault and the frame is silently half empty: the first NV16
# capture on the MacBookAir7,2 had exactly 50% of its luma rows zero, in a
# strict every-other-row pattern, because the output-config command was still
# sending the packed formats' width*2 stride for a one-byte-per-pixel plane.
plane_zero_rows() {
    local file="$1" offset="$2" stride="$3" rows="$4" i zero=0 sum

    for i in $(seq 0 $(( rows - 1 ))); do
        sum="$(dd if="$file" bs=1 skip=$(( offset + i * stride )) count="$stride" \
               status=none 2>/dev/null | od -An -tu1 -v |
               awk '{for (j = 1; j <= NF; j++) s += $j} END{print s + 0}')"
        [ "$sum" -eq 0 ] && zero=$(( zero + 1 ))
    done
    awk -v z="$zero" -v n="$rows" 'BEGIN{printf "%.1f", z * 100 / n}'
}

# Mean of the Cb and Cr components of a packed YUYV frame: bytes go Y Cb Y Cr,
# so Cb is every 4th byte from offset 1 and Cr every 4th from offset 3. YUYV is
# a validated format on this hardware, which makes it the reference NV16's
# chroma has to agree with - far stronger evidence than any absolute threshold,
# because it is the same sensor looking at the same room.
yuyv_chroma_means() {
    local file="$1" frame_size="$2" size complete

    size="$(stat -c %s "$file" 2>/dev/null || echo 0)"
    complete=$(( size / frame_size ))
    [ "$complete" -gt 0 ] || return 1
    dd if="$file" bs="$frame_size" skip=$(( complete - 1 )) count=1 \
       status=none 2>/dev/null | od -An -tu1 -v |
        awk '{
                 for (i = 1; i <= NF; i++) {
                     m = byte % 4
                     if (m == 1) { cb += $i; nb++ }
                     else if (m == 3) { cr += $i; nr++ }
                     byte++
                 }
             }
             END {
                 if (!nb || !nr)
                     exit 1
                 printf "%.1f %.1f\n", cb / nb, cr / nr
             }'
}

# "mean min max" over six samples spread through a byte range of a file. Used
# on the luma and chroma halves of an NV16 frame separately, because the whole
# question there is whether the two halves hold different kinds of data.
plane_stats() {
    local file="$1" offset="$2" len="$3" step i off
    step=$(( len / 6 ))
    [ "$step" -gt 0 ] || return 1
    for i in 0 1 2 3 4 5; do
        off=$(( offset + i * step ))
        dd if="$file" bs=1 skip="$off" count=4096 status=none 2>/dev/null
    done | od -An -tu1 -v |
        awk '{
                 for (i = 1; i <= NF; i++) {
                     v = $i
                     s += v
                     n++
                     if (n == 1 || v < min) min = v
                     if (n == 1 || v > max) max = v
                 }
             }
             END {
                 if (!n)
                     exit 1
                 printf "%.1f %d %d\n", s / n, min, max
             }'
}

# One field out of v4l2-ctl --get-fmt-video, by its printed label.
fmt_field() {
    v4l2-ctl --device "$DEVICE" --get-fmt-video 2>/dev/null |
        sed -n "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*//p" | head -1
}

# "left top width height" of the current crop rectangle.
current_crop() {
    v4l2-ctl --device "$DEVICE" --get-selection=target=crop 2>/dev/null |
        sed -n 's/.*Left \([0-9-]*\), Top \([0-9-]*\), Width \([0-9]*\), Height \([0-9]*\).*/\1 \2 \3 \4/p' |
        head -1
}

# Dynamic debug turns on the dev_dbg lines - notably "DDR verification passed
# over N words", which is the only direct measurement of what the widened
# probe check costs.
#
# It has to be passed as a module parameter, not written to
# dynamic_debug/control beforehand: a module's callsites do not exist until it
# is loaded, so a `module facetimehd +p` query for an unloaded module matches
# nothing and the write fails. Setting it at load time is what actually gets
# the probe-path dev_dbg lines, which are the ones we need - by the time the
# module is loaded, probe has already run.
#
# Scoped to fthd_hw.c rather than a blanket +p: the DDR line we need lives
# there, and a whole-module +p adds enough extra output to hasten the ring
# wrap described above - which is how the first fix for this broke the
# suspend section.
DYNDBG_ARG="dyndbg=file fthd_hw.c +p"

# Reload from scratch with the dmesg cursor set just before probe, so
# dmesg_driver returns this probe's messages and not the previous one's.
load_module() {
    modprobe -r "$MODULE_NAME" 2>/dev/null || true
    sleep 1
    dmesg_mark
    # Fall back to a bare load if the kernel was built without dynamic debug,
    # which makes the dyndbg parameter unknown and modprobe fail outright.
    modprobe "$MODULE_NAME" "$DYNDBG_ARG" 2>/dev/null ||
        modprobe "$MODULE_NAME"
}

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "${STREAM_PID:-}" ]; then
        if [ -n "$METERING_RESTORE_NODE" ] &&
           [ -n "$METERING_ORIGINAL" ] &&
           [ -w "$METERING_RESTORE_NODE" ]; then
            printf 'mode%s\n' "$METERING_ORIGINAL" \
                >"$METERING_RESTORE_NODE" 2>/dev/null || true
        fi
        kill "$STREAM_PID" 2>/dev/null || true
        wait "$STREAM_PID" 2>/dev/null || true
    fi
    return 0
}
trap cleanup EXIT

: >"$REPORT"
: >"$REPORT.results"
log "facetimehd hardware validation"
log "date:    $(date -Is)"
log "kernel:  $(uname -r)"
log "model:   $(dmi_product_name 2>/dev/null || echo unknown)"
log "slot:    ${SLOT:-not found}"
log "sections: $SECTIONS"
log "modinfo:"
modinfo "$MODULE_NAME" 2>>"$REPORT" | sed 's/^/  /' >>"$REPORT" || true

info "Report: $REPORT"

# ============================================================================
# Section: probe
# DOWNSTREAM.md - "Safety and correctness"
#
# PLL, DDR and memory-verification failures used to be logged and ignored;
# they now fail probe. The regression this is hunting for is a machine that
# worked before and no longer probes - so the useful output is not just
# pass/fail but *which* check fired.
# ============================================================================
if wants probe; then
    step "probe: does the driver still come up on this machine?"
    log_section "SECTION probe"

    if load_module >>"$REPORT" 2>&1; then
        if wait_for_device; then
            result PASS probe.load "module loaded, $MODULE_NAME claims $DEVICE"
            # The driver's default format is NV12, the ISP's own output. This
            # is the section that can check it: it reloads the module, and the
            # format is device-wide state that any later section may have
            # changed by the time it runs.
            probe_fmt="$(fmt_field 'Pixel Format')"
            case "$probe_fmt" in
                *NV12*)
                    result PASS probe.default_fmt \
                        "a freshly loaded driver reports NV12" ;;
                *)
                    result FAIL probe.default_fmt \
                        "a freshly loaded driver reports '$probe_fmt', not NV12" ;;
            esac
        else
            result FAIL probe.node "module loaded but no video node appeared"
        fi
    else
        result FAIL probe.load "modprobe failed - the driver refuses this machine"
    fi

    dmesg_driver >>"$REPORT"

    # Classify against the exact strings the hardened checks emit, so a report
    # says "DDR PLL stage 2" rather than "it broke".
    DRV_LOG="$(dmesg_driver)"
    while IFS='|' read -r pattern label; do
        [ -n "$pattern" ] || continue
        if printf '%s' "$DRV_LOG" | grep -qi -- "$pattern"; then
            result FAIL "probe.check" "hardware check fired: $label"
        fi
    done <<'EOF'
Failed to lock the DDR PLL|DDR PLL never locked
Failed to lock DDR PHY PLL in stage 1|DDR PHY PLL stage 1
Failed to lock DDR PHY PLL in stage 2|DDR PHY PLL stage 2
Failed to lock DDR PHY PLL in stage 3|DDR PHY PLL stage 3
First DDR40 VDL calibration failed|DDR40 VDL calibration
DDR verification failed|DDR memory verification (widened at probe)
Failed to init S2 PCIe link|S2 PCIe link init
PCI link in illegal state|PCI link state
Timeout waiting for STRAP valid|STRAP timeout
Failed to read PCI config|PCI config read
EOF

    # Non-fatal, but worth surfacing: the fixed DDR timings assume 450MHz.
    if printf '%s' "$DRV_LOG" | grep -qi "should be 450 MHz\|Unsupported DDR speed"; then
        result WARN probe.ddrfreq "DDR is not running at 450MHz - see report"
    fi
fi

# ============================================================================
# Section: timing
# DOWNSTREAM.md - "DDR"
#
# 64K words is 64K non-posted PCIe reads. Total module load measured around
# 640 ms on the MacBookAir7,2; this times the whole probe and prints a per-line
# delta profile so the DDR verification step can be read off directly rather
# than inferred.
# ============================================================================
if wants timing; then
    step "timing: what does the widened DDR check cost at probe?"
    log_section "SECTION timing"

    modprobe -r "$MODULE_NAME" 2>/dev/null || true
    sleep 1
    dmesg_mark
    t0="$(date +%s%N)"
    if modprobe "$MODULE_NAME" "$DYNDBG_ARG" >>"$REPORT" 2>&1 ||
       modprobe "$MODULE_NAME" >>"$REPORT" 2>&1; then
        t1="$(date +%s%N)"
        elapsed_ms=$(( (t1 - t0) / 1000000 ))
        result INFO timing.modprobe "modprobe wall time: ${elapsed_ms}ms"
        if [ "$elapsed_ms" -gt 2000 ]; then
            result WARN timing.modprobe \
                "probe took ${elapsed_ms}ms - if this is objectionable, lower MEM_VERIFY_NUM_PROBE"
        else
            result PASS timing.modprobe "probe cost is acceptable (${elapsed_ms}ms)"
        fi

        # Per-message deltas from the kernel's own timestamps. The largest gap
        # is the answer; DDR verification is the line to look for next to it.
        log ""
        log "--- probe timeline (delta ms | message) ---"
        dmesg_driver | awk '
            match($0, /\[[ ]*[0-9]+\.[0-9]+\]/) {
                ts = substr($0, RSTART+1, RLENGTH-2) + 0
                if (prev != "") printf "%8.1f | %s\n", (ts-prev)*1000, $0
                prev = ts
            }' >>"$REPORT"

        biggest="$(dmesg_driver | awk '
            match($0, /\[[ ]*[0-9]+\.[0-9]+\]/) {
                ts = substr($0, RSTART+1, RLENGTH-2) + 0
                if (prev != "" && (ts-prev) > max) { max = ts-prev; line = $0 }
                prev = ts
            } END { if (line != "") printf "%.0fms at: %s\n", max*1000, line }')"
        [ -n "$biggest" ] && result INFO timing.slowest "longest gap: $biggest"

        if dmesg_driver | grep -qi "DDR verification passed"; then
            result PASS timing.ddr "$(dmesg_driver | grep -i 'DDR verification passed' | tail -1 | sed 's/.*facetimehd[^ ]* //')"
        else
            result INFO timing.ddr \
                "no DDR verification line (needs dynamic debug; is CONFIG_DYNAMIC_DEBUG on?)"
        fi
        wait_for_device || true
    else
        result FAIL timing.modprobe "modprobe failed during timing run"
    fi
fi

# ============================================================================
# Section: controls
# DOWNSTREAM.md - V4L2_CID_POWER_LINE_FREQUENCY and
#                 V4L2_CID_EXPOSURE_AUTO
#
# Static firmware analysis confirms that opcode 0x8208 reads the one-word
# payload the driver sends. This section checks accepted values, capture, and
# (interactively) whether those values actually change mains-light banding.
# ============================================================================
if wants controls; then
    step "controls: anti-banding and automatic/manual exposure"
    log_section "SECTION controls"

    [ -n "$DEVICE" ] || wait_for_device || true
    if [ -z "$DEVICE" ]; then
        result SKIP controls "no video node"
    else
        v4l2-ctl --device "$DEVICE" --list-ctrls >>"$REPORT" 2>&1 || true

        # --- power_line_frequency -------------------------------------------
        if v4l2-ctl --device "$DEVICE" --list-ctrls 2>/dev/null |
                grep -q power_line_frequency; then
            for val in 0 1 2; do
                case "$val" in
                    0) label=Disabled ;;
                    1) label=50Hz ;;
                    *) label=60Hz ;;
                esac
                dmesg_mark
                if v4l2-ctl --device "$DEVICE" \
                        --set-ctrl power_line_frequency="$val" >>"$REPORT" 2>&1; then
                    got="$(v4l2-ctl --device "$DEVICE" --get-ctrl power_line_frequency \
                           2>/dev/null | sed -n 's/^power_line_frequency: //p')"
                    if [ "$got" = "$val" ]; then
                        result PASS "controls.plf.$label" "accepted and read back"
                    else
                        result FAIL "controls.plf.$label" \
                            "set succeeded but reads back '$got'"
                    fi
                else
                    result FAIL "controls.plf.$label" "S_CTRL failed for opcode 0x8208"
                fi
                dmesg_driver >>"$REPORT"
            done

            # Banding is what the control exists to fix, and only an eye can
            # confirm it. Capture one frame per setting for later comparison.
            if [ "$INTERACTIVE" = 1 ]; then
                info "Point the camera at a wall lit by mains lighting, then press Enter."
                read -r _ || true
                for val in 0 1 2; do
                    v4l2-ctl --device "$DEVICE" --set-ctrl power_line_frequency="$val" \
                        >/dev/null 2>&1 || continue
                    sleep 2
                    v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=1 \
                        --stream-to="/tmp/facetimehd-plf-$val.raw" >/dev/null 2>&1 || true
                done
                result INFO controls.plf.frames \
                    "wrote /tmp/facetimehd-plf-{0,1,2}.raw - compare for banding"
            fi
            v4l2-ctl --device "$DEVICE" --set-ctrl power_line_frequency=0 \
                >/dev/null 2>&1 || true
        else
            result SKIP controls.plf "power_line_frequency not exposed"
        fi

        # --- auto exposure: named opcodes, unverified behaviour ------------
        # V4L2_CID_EXPOSURE_AUTO (0x009a0901) is printed by current v4l-utils
        # as "auto_exposure", and by older releases as "exposure_auto". Match
        # the control ID instead of either spelling, then use whichever name
        # this v4l2-ctl actually accepts for --set-ctrl.
        AE_NAME=""
        if v4l2-ctl --device "$DEVICE" --list-ctrls 2>/dev/null |
                grep -q '0x009a0901'; then
            AE_NAME="$(v4l2-ctl --device "$DEVICE" --list-ctrls 2>/dev/null |
                       sed -n 's/^[[:space:]]*\([a-z_]*\)[[:space:]]*0x009a0901.*/\1/p' |
                       head -1)"
        fi
        if [ -n "$AE_NAME" ]; then
            # 0 = AUTO, 1 = MANUAL in the V4L2 menu.
            for val in 1 0; do
                case "$val" in
                    0) label=auto ;;
                    *) label=manual ;;
                esac
                if v4l2-ctl --device "$DEVICE" \
                        --set-ctrl "$AE_NAME"="$val" >>"$REPORT" 2>&1; then
                    result PASS "controls.ae.$label" "accepted"
                else
                    result FAIL "controls.ae.$label" "S_CTRL failed"
                fi
            done

            if capture_ok 10; then
                result PASS controls.ae.stream "capture still works after toggling AE"
            else
                result FAIL controls.ae.stream "capture broke after toggling AE"
            fi

            # The real question is whether it *does* anything. Manual AE means
            # luma must NOT track a lighting change; auto means it must. Only a
            # human can change the lighting, so this stays interactive.
            if [ "$INTERACTIVE" = 1 ]; then
                v4l2-ctl --device "$DEVICE" --set-ctrl "$AE_NAME"=1 >/dev/null 2>&1 || true
                sleep 2
                base_manual="$(mean_luma || echo "")"
                # Partly shade, do not cover. Covering the sensor completely
                # drove luma to exactly 0.0 in both AUTO and MANUAL on two
                # runs: with no photons there is nothing for auto-exposure to
                # amplify, so both branches read the same floor and the test
                # cannot discriminate no matter what the firmware does.
                # Dimming leaves signal for AE to work on.
                info "PARTLY shade the camera - a hand a few inches away, or"
                info "half-cover the lens. Do NOT cover it completely."
                info "Then press Enter."
                read -r _ || true
                sleep 2
                dark_manual="$(mean_luma || echo "")"

                v4l2-ctl --device "$DEVICE" --set-ctrl "$AE_NAME"=0 >/dev/null 2>&1 || true
                sleep 3
                dark_auto="$(mean_luma || echo "")"
                info "Remove the shade, then press Enter."
                read -r _ || true
                sleep 3
                light_auto="$(mean_luma || echo "")"

                log "luma manual(lit)=$base_manual manual(dark)=$dark_manual"
                log "luma auto(dark)=$dark_auto auto(lit)=$light_auto"
                result INFO controls.ae.luma \
                    "manual lit=$base_manual dark=$dark_manual | auto dark=$dark_auto lit=$light_auto"

                # Direction matters, not just difference. Auto-exposure on a
                # dimmed scene should raise gain and so push luma *up* relative
                # to the manual reading of the same scene. A bare "they differ"
                # test passes on noise, and passes just as happily when AUTO
                # comes out darker - which is the opposite of the control
                # working.
                if awk -v m="$dark_manual" -v a="$dark_auto" \
                       'BEGIN{exit !(m+0 < 1 && a+0 < 1)}' 2>/dev/null &&
                   [ -n "$dark_manual" ] && [ -n "$dark_auto" ]; then
                    # Both on the floor: the shade was total, so there was no
                    # signal either setting could act on. Says nothing about AE.
                    result WARN controls.ae.effect \
                        "both readings floored at 0 - camera was fully covered, re-run and only partly shade it"
                elif [ -n "$base_manual" ] && [ -n "$dark_manual" ] &&
                     awk -v l="$base_manual" -v d="$dark_manual" \
                         'BEGIN{exit !(d+0 >= l+0 - 5)}'; then
                    # The manual pair is the control: with AE off, shading the
                    # lens must pull luma down. If it did not, the shade was
                    # never on the lens for that reading - so manual(dark) and
                    # auto(dark) sampled different scenes, and their difference
                    # is a lighting artefact that would otherwise be scored as
                    # AE running backwards.
                    result WARN controls.ae.effect \
                        "shading did not darken the MANUAL reading ($base_manual -> $dark_manual) - the shade was not on the lens for it, so the two dark readings are different scenes; re-run and hold the shade steady across both"
                elif [ -n "$dark_manual" ] && [ -n "$dark_auto" ] &&
                     awk -v m="$dark_manual" -v a="$dark_auto" \
                         'BEGIN{exit !(a+0 < 1 && m+0 >= 1)}'; then
                    # Only the AUTO reading floored: the lens was covered far
                    # harder for it than for the manual one. Same reason as the
                    # both-floored case - no photons, nothing for AE to
                    # amplify - but it would otherwise land in the "backwards"
                    # branch below and read as an AE fault.
                    result WARN controls.ae.effect \
                        "AUTO reading floored at $dark_auto while MANUAL held $dark_manual - the lens was covered harder for the AUTO step, re-run with the same partial shade for both"
                elif [ -n "$dark_manual" ] && [ -n "$dark_auto" ]; then
                    if awk -v a="$dark_auto" -v m="$dark_manual" \
                           'BEGIN{exit !(a > m + 5)}'; then
                        result PASS controls.ae.effect \
                            "AUTO raised luma on a dark scene ($dark_manual -> $dark_auto) - AE is working"
                    elif awk -v a="$dark_auto" -v m="$dark_manual" \
                             'BEGIN{exit !(a < m - 5)}'; then
                        result WARN controls.ae.effect \
                            "AUTO came out darker than MANUAL ($dark_manual -> $dark_auto) - backwards, re-run with steady lighting before trusting it"
                    else
                        result WARN controls.ae.effect \
                            "AUTO and MANUAL within noise ($dark_manual vs $dark_auto) - control may be a silent no-op"
                    fi
                fi
            else
                result SKIP controls.ae.effect "needs --interactive to change the lighting"
            fi
            v4l2-ctl --device "$DEVICE" --set-ctrl "$AE_NAME"=0 >/dev/null 2>&1 || true
        else
            result SKIP controls.ae "V4L2_CID_EXPOSURE_AUTO (0x009a0901) not exposed"
        fi
    fi
fi

# ============================================================================
# Section: runtimepm
# DOWNSTREAM.md - "Power management"
#
# The failure mode to catch: camera works on first use after boot but not
# after sitting idle. So the test is idle -> suspended -> open -> capture,
# repeated, because a firmware reload that works once can still leak.
# ============================================================================
if wants runtimepm; then
    step "runtimepm: does the camera survive being parked and woken?"
    log_section "SECTION runtimepm"

    if [ -z "$PCI_DIR" ]; then
        result SKIP runtimepm "PCI device not found in sysfs"
    elif [ "$(cat /sys/module/$MODULE_NAME/parameters/runtime_pm 2>/dev/null)" = "N" ]; then
        result SKIP runtimepm "loaded with runtime_pm=0"
    else
        # The driver calls pm_runtime_allow() itself, so power/control should
        # already read "auto" with nothing else on the system touching it.
        # Anything else means something external overrode the driver - TLP with
        # RUNTIME_PM_ON_AC=on, 'powertop --auto-tune', a udev rule - and that is
        # worth reporting rather than silently papering over, because it is the
        # configuration the user is actually running. Report, then set it, so
        # the rest of the section still tests the driver.
        ctrl="$(cat "$PCI_DIR/power/control" 2>/dev/null || echo unknown)"
        if [ "$ctrl" = auto ]; then
            result PASS runtimepm.control "power/control=auto (driver allowed it)"
        else
            result WARN runtimepm.control \
                "power/control=$ctrl - something outside the driver disabled runtime PM; forcing auto for this test"
            echo auto >"$PCI_DIR/power/control" 2>/dev/null || true
        fi
        delay="$(cat "$PCI_DIR/power/autosuspend_delay_ms" 2>/dev/null || echo 5000)"
        result INFO runtimepm.delay "autosuspend_delay_ms=$delay"
        wait_s=$(( delay / 1000 + 4 ))
        [ "$wait_s" -lt "$IDLE_WAIT" ] && wait_s="$IDLE_WAIT"

        for cycle in 1 2; do
            info "cycle $cycle: waiting ${wait_s}s for the device to park"
            sleep "$wait_s"
            st="$(runtime_status || echo unknown)"
            log "cycle $cycle idle runtime_status=$st"
            if [ "$st" = suspended ]; then
                result PASS "runtimepm.park.$cycle" "device parked (runtime_status=suspended)"
            else
                result FAIL "runtimepm.park.$cycle" \
                    "device did not park after ${wait_s}s idle (runtime_status=$st)"
            fi

            dmesg_mark
            [ -n "$DEVICE" ] || wait_for_device || true
            if [ -n "$DEVICE" ] && capture_ok 10; then
                result PASS "runtimepm.wake.$cycle" "captured after idle - firmware reloaded"
            else
                result FAIL "runtimepm.wake.$cycle" \
                    "capture FAILED after idle - this is the runtime_pm=0 case"
            fi
            st="$(runtime_status || echo unknown)"
            log "cycle $cycle post-capture runtime_status=$st"
            dmesg_driver >>"$REPORT"

            if dmesg_since | grep -qi "firmware stopped responding"; then
                result FAIL "runtimepm.wedged.$cycle" \
                    "firmware wedged during the wake cycle"
            fi
        done

        # Reading a debugfs file must itself power the camera up - that is the
        # documented reason the accessors take a runtime-PM reference.
        dbg="/sys/kernel/debug/$MODULE_NAME/$SLOT/channel_io"
        if [ -r "$dbg" ]; then
            sleep "$wait_s"
            [ "$(runtime_status || echo x)" = suspended ] &&
                info "device parked; reading debugfs should wake it"
            if head -c 128 "$dbg" >/dev/null 2>&1; then
                result PASS runtimepm.debugfs "debugfs read woke the device"
            else
                result FAIL runtimepm.debugfs "debugfs read failed while parked"
            fi
        else
            result SKIP runtimepm.debugfs "debugfs not mounted or not readable"
        fi
    fi
fi

# ============================================================================
# Section: suspend
# DOWNSTREAM.md - "Power management"
#
# Expected: the machine sleeps instead of refusing to, and the viewer that was
# streaming when the lid closed is still streaming when it opens - the driver
# parks the stream and puts it back itself. Two earlier behaviours this is
# meant to catch a regression to: refusing to suspend at all with the camera
# open, and coming back with the queue errored so the viewer had to be
# restarted.
# ============================================================================
if wants suspend; then
    step "suspend: system sleep with the camera streaming"
    log_section "SECTION suspend"

    # The lid switch, not rtcwake. An RTC alarm reliably *started* the suspend
    # on this hardware but never held it: every run came back after ~5s of a
    # 20s alarm, so the duration check was permanently WARN and told us nothing
    # about the driver. The lid is the way a MacBook is actually suspended, it
    # has no competing wakeup source, and the person running this is sitting in
    # front of the machine anyway. It does mean the section needs a terminal.
    if [ "$INTERACTIVE" = 0 ]; then
        result SKIP suspend "needs a terminal - the lid prompt drives this section"
    elif [ -z "$DEVICE" ] && ! wait_for_device; then
        result SKIP suspend "no video node"
    fi

    if wants suspend && [ "$INTERACTIVE" = 1 ] && [ -n "$DEVICE" ]; then
        dmesg_mark
        # Its own log, not $REPORT: v4l2-ctl prints a character per captured
        # frame, so the file growing is the evidence that frames are still
        # arriving. Nothing else may write to it or that measurement is noise.
        STREAM_LOG="$(mktemp)"
        v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=100000 \
                 --stream-to=/dev/null >"$STREAM_LOG" 2>&1 &
        STREAM_PID=$!
        sleep 3

        if ! kill -0 "$STREAM_PID" 2>/dev/null; then
            result FAIL suspend.stream "stream died before the suspend even started"
        else
            result INFO suspend.stream "streaming (pid $STREAM_PID), waiting for the lid"

            printf '\n'
            warn "The camera is streaming right now. To test suspend:"
            warn ""
            warn "    1. CLOSE the lid now."
            warn "    2. Leave it closed for at least ${SUSPEND_SECS} seconds."
            warn "    3. OPEN the lid again."
            warn ""
            warn "This script is frozen along with the machine and picks up on"
            warn "its own once you open the lid. Do not press anything."
            printf '\n'

            before="$(date +%s)"
            # This loop is frozen with everything else while the machine is
            # down, so it resumes by itself; it only has to notice that the
            # resume happened. Poll the PM records rather than the clock -
            # "PM: suspend exit" is the unambiguous signal that a full
            # suspend/resume cycle completed.
            waited=0
            while [ "$waited" -lt "$LID_TIMEOUT" ]; do
                if dmesg_since | grep -qi "PM: suspend exit"; then
                    break
                fi
                sleep 2
                waited=$(( waited + 2 ))
            done
            after="$(date +%s)"
            slept=$(( after - before ))

            timed_out=0
            [ "$waited" -ge "$LID_TIMEOUT" ] && timed_out=1

            # Wall-clock alone cannot tell "the driver refused to suspend" from
            # "the machine suspended and something woke it early" - both come
            # back sooner than asked. Only the kernel's own PM records can, so
            # capture them; a short sleep is otherwise misreported as a driver
            # bug. -EBUSY (-16) out of fthd_suspend is the specific regression
            # this section exists to catch.
            pm_log="$(dmesg_since | grep -i "PM: suspend\|failed to suspend\|$MODULE_NAME" || true)"
            printf '%s\n' "$pm_log" >>"$REPORT"

            if check_ring_wrap; then
                # The evidence was evicted before we could read it. Saying
                # "suspend never started" here would be inventing a result.
                result WARN suspend.entered \
                    "kernel ring buffer wrapped - PM records lost, cannot judge (raise log_buf_len)"
            elif printf '%s' "$pm_log" | grep -qi "fthd_suspend.*returns -16\|$MODULE_NAME.*failed to suspend"; then
                result FAIL suspend.refused \
                    "driver returned -EBUSY from fthd_suspend - it is blocking system sleep"
            elif printf '%s' "$pm_log" | grep -qi "PM: suspend entry"; then
                result PASS suspend.entered \
                    "machine entered suspend with the camera streaming (not refused)"
                # Elapsed includes however long you took to reach for the lid,
                # so it is context for the log, not a pass criterion. Whether
                # the machine suspended at all is the driver question, and the
                # PM records above already answered it.
                result INFO suspend.slept "${slept}s elapsed from prompt to resume"
                if printf '%s' "$pm_log" | grep -qi "Some devices failed to suspend"; then
                    if printf '%s' "$pm_log" | grep -qi "$MODULE_NAME.*failed to suspend"; then
                        result FAIL suspend.devices "facetimehd is the device that failed"
                    else
                        result WARN suspend.devices \
                            "some device failed to suspend, but not facetimehd - see report"
                    fi
                fi
            elif [ "$timed_out" -eq 1 ]; then
                # Nobody closed the lid, or this machine does not suspend on
                # lid close. Either way the driver was never asked to do
                # anything, so this is not a failure of it.
                result SKIP suspend.entered \
                    "no suspend in ${LID_TIMEOUT}s - lid never closed, or this machine does not sleep on lid close"
            else
                result FAIL suspend.entered \
                    "resume seen but no 'PM: suspend entry' - suspend never started"
            fi

            # The point of the whole section: the viewer that was running
            # before the lid closed must still be capturing now, without
            # anybody restarting it. Alive is necessary but not sufficient - a
            # viewer sitting in a poll() that never completes is also alive -
            # so measure whether its output is still growing.
            frames_before="$(wc -c <"$STREAM_LOG" 2>/dev/null || echo 0)"
            sleep 3
            frames_after="$(wc -c <"$STREAM_LOG" 2>/dev/null || echo 0)"

            if ! kill -0 "$STREAM_PID" 2>/dev/null; then
                result FAIL suspend.viewer \
                    "viewer exited across the suspend - the stream was not resumed"
            elif [ "$frames_after" -gt "$frames_before" ]; then
                result PASS suspend.viewer \
                    "viewer kept capturing across the suspend without restarting"
            else
                result FAIL suspend.viewer \
                    "viewer alive but no new frames after resume (stalled, not resumed)"
            fi
            kill "$STREAM_PID" 2>/dev/null || true
            wait "$STREAM_PID" 2>/dev/null || true
            STREAM_PID=""
            tail -n 20 "$STREAM_LOG" >>"$REPORT" 2>/dev/null || true
            rm -f "$STREAM_LOG"

            # The half that matters: a picture must come back afterwards.
            sleep 2
            if capture_ok 10; then
                result PASS suspend.recover "capture works again after resume"
            else
                result FAIL suspend.recover "camera does not recover after resume"
            fi
            post_suspend_log="$(dmesg_since || true)"
            printf '%s\n' "$post_suspend_log" >>"$REPORT"
            if grep -Eqi \
                    'failed to stop firmware channel|buffer return.*(invalid state|unknown tag)|DMAR:.*\bfault\b|IOMMU.*\bfault\b' \
                    <<<"$post_suspend_log"; then
                result FAIL suspend.post_faults \
                    "driver/DMA faults appeared while stopping or recovering the resumed stream"
            else
                result PASS suspend.post_faults \
                    "no channel-stop, buffer-tag, IOMMU or DMAR faults after resume"
            fi
        fi
    fi
fi

# ============================================================================
# Section: wedged
# DOWNSTREAM.md - "Safety and correctness", firmware command timeouts
#
# There is no known way to make the firmware stop answering, so this cannot be
# provoked. It is observational: scan for the message and for the rate-limited
# buffer-return warnings, which are the other thing that should never appear
# on a healthy machine.
# ============================================================================
if wants wedged; then
    step "wedged: scanning for firmware-timeout and buffer-return warnings"
    log_section "SECTION wedged"

    full="$(dmesg 2>/dev/null | grep -i "$MODULE_NAME\|fthd" || true)"
    printf '%s\n' "$full" >>"$REPORT"

    if printf '%s' "$full" | grep -qi "firmware stopped responding"; then
        result FAIL wedged.timeout \
            "firmware stopped responding - the wedged path fired, capture the report"
    else
        result PASS wedged.timeout "no firmware timeout observed"
    fi

    if grep -Eqi \
            'unknown tag|invalid state|wrong entry count|unreadable descriptor|failed to stop firmware channel' \
            <<<"$full"; then
        result FAIL wedged.buffers \
            "stream teardown or buffer-return mismatch was logged"
    else
        result PASS wedged.buffers "no stream-teardown or buffer-return mismatches"
    fi

    all_kernel="$(dmesg 2>/dev/null || true)"
    if grep -Eqi 'DMAR:.*\bfault\b|IOMMU.*\bfault\b' <<<"$all_kernel"; then
        result FAIL wedged.dma "IOMMU/DMAR fault logged - hardware DMA escaped a live mapping"
    else
        result PASS wedged.dma "no IOMMU/DMAR faults"
    fi

    if printf '%s' "$full" | grep -qi "Firmware did not establish the required IPC channels"; then
        result FAIL wedged.ipc "IPC channel validation rejected the firmware's table"
    fi
fi

# ============================================================================
# Section: readbacks
#
# Each debugfs read issues one reverse-engineered GET while a channel is already
# streaming. No setter, control replay, or arbitrary opcode path is involved.
# The first full run confirmed every response and a fault-free teardown on this
# firmware, so this read-only section is now part of the default suite.
# ============================================================================
if wants readbacks; then
    step "readbacks: testing root-only firmware GETs during a live stream"
    log_section "SECTION readbacks"

    [ -n "$DEVICE" ] || wait_for_device || die "no video node to stream from"
    DEBUGFS_DEVICE="/sys/kernel/debug/facetimehd/${SLOT}"
    if [ ! -d "$DEBUGFS_DEVICE" ]; then
        result SKIP readbacks.debugfs \
            "debugfs device directory is unavailable (mount debugfs first)"
    else
        dmesg_mark
        v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=100000 \
                 --stream-to=/dev/null >>"$REPORT" 2>&1 &
        STREAM_PID=$!
        sleep 2
        if ! kill -0 "$STREAM_PID" 2>/dev/null; then
            result FAIL readbacks.stream "stream exited before GET testing"
        else
            while read -r node; do
                [ -n "$node" ] || continue
                if value="$(cat "$DEBUGFS_DEVICE/$node" 2>>"$REPORT")"; then
                    # crop_raw returns two rectangles on two lines; the summary
                    # is one line per result, so flatten before reporting.
                    value="$(printf '%s' "$value" | tr '\n' ' ' | sed 's/ *$//')"
                    result PASS "readbacks.$node" "$value"
                else
                    result FAIL "readbacks.$node" "GET failed"
                fi
            done <<'EOF'
sensor_temperature_raw
awb_cct_raw
ae_bias_raw
ae_gain_cap_raw
ae_gain_cap_min_raw
ae_gain_cap_max_with_exp_raw
ae_gain_cap_off_raw
ae_integration_time_max_raw
ae_sensor_integration_time_min_raw
ae_sensor_integration_time_max_raw
ae_metering_mode_raw
ae_frame_rate_max_raw
ae_frame_rate_min_raw
awb_2nd_gain_raw
crop_raw
EOF

            # Crop GET against the rectangle the driver actually asked for.
            # This is the point of the node: CISP_CMD_CH_CROP_GET returns two
            # four-word rectangles and it is not established which is which, so
            # the check is that *some* returned rectangle matches the request.
            # The driver sends (left, top, left+width, top+height), so the
            # expected tuple is derived that way and not from width/height.
            crop_now="$(current_crop)"
            if [ -z "$crop_now" ]; then
                result WARN readbacks.crop_geometry \
                    "could not read the current crop rectangle to compare against"
            else
                read -r c_l c_t c_w c_h <<CROPEOF
$crop_now
CROPEOF
                want="$c_l $c_t $((c_l + c_w)) $((c_t + c_h))"
                if grep -qx -- "$want" "$DEBUGFS_DEVICE/crop_raw" 2>/dev/null; then
                    result PASS readbacks.crop_geometry \
                        "a returned rectangle matches the requested $want"
                else
                    # Not a failure: the firmware may hold this geometry in a
                    # different encoding, and nothing about the two groups'
                    # meaning is established yet. Record both so the next run
                    # has the raw evidence to interpret.
                    result WARN readbacks.crop_geometry \
                        "requested $want, firmware returned $(tr '\n' '/' < "$DEBUGFS_DEVICE/crop_raw" 2>/dev/null)"
                fi
            fi

            # The same AWB CCT value through its V4L2 control, which is what a
            # normal application sees. It is read-only and volatile, so this
            # reaches the same firmware GET without any SET being possible; the
            # debugfs value above is the reference it has to agree with.
            cct_debugfs="$(cat "$DEBUGFS_DEVICE/awb_cct_raw" 2>/dev/null || true)"
            cct_ctrl="$(v4l2-ctl --device "$DEVICE" --get-ctrl awb_cct_estimate \
                        2>/dev/null | sed -n 's/^awb_cct_estimate: //p')"
            if [ -z "$cct_ctrl" ]; then
                result FAIL readbacks.awb_cct_ctrl \
                    "awb_cct_estimate is not exposed as a V4L2 control"
            elif [ -z "$cct_debugfs" ]; then
                result WARN readbacks.awb_cct_ctrl \
                    "control reads $cct_ctrl but the debugfs reference was unreadable"
            elif awk -v a="$cct_ctrl" -v b="$cct_debugfs" \
                     'BEGIN{d=a-b; if(d<0)d=-d; exit !(d <= b * 0.25 + 50)}'; then
                # AWB keeps estimating between the two reads, so they are close
                # rather than equal; a control wired to something else entirely
                # would not land in the same neighbourhood at all.
                result PASS readbacks.awb_cct_ctrl \
                    "control reads $cct_ctrl against a debugfs $cct_debugfs"
            else
                result FAIL readbacks.awb_cct_ctrl \
                    "control reads $cct_ctrl but debugfs reads $cct_debugfs - not the same value"
            fi

            # Read-only is the whole safety argument: a writable control would
            # be replayed at every STREAMON. Judge the outcome rather than
            # v4l2-ctl's exit status, which for a read-only control is a
            # diagnostic of its own rather than the kernel's answer. 12345 K is
            # not a colour temperature the ISP would report on its own.
            v4l2-ctl --device "$DEVICE" --set-ctrl awb_cct_estimate=12345 \
                >>"$REPORT" 2>&1 || true
            cct_after="$(v4l2-ctl --device "$DEVICE" --get-ctrl awb_cct_estimate \
                         2>/dev/null | sed -n 's/^awb_cct_estimate: //p')"
            if [ "$cct_after" = 12345 ]; then
                result FAIL readbacks.awb_cct_ro \
                    "awb_cct_estimate took a written value - it is not read-only, so STREAMON can replay it"
            else
                result PASS readbacks.awb_cct_ro \
                    "awb_cct_estimate ignored a write and still reads $cct_after"
            fi
        fi
        kill "$STREAM_PID" 2>/dev/null || true
        wait "$STREAM_PID" 2>/dev/null || true
        STREAM_PID=""
        dmesg_driver >>"$REPORT"
        if dmesg_since | grep -Eqi \
                'firmware stopped responding|failed to stop firmware channel|unknown tag|IOMMU.*fault|DMAR:.*fault'; then
            result FAIL readbacks.post_faults \
                "firmware, teardown, or DMA fault followed a GET"
        else
            result PASS readbacks.post_faults \
                "all GETs left streaming and teardown fault-free"
        fi
    fi
fi

# ============================================================================
# Section: readback-profile (opt-in, interactive)
#
# Observe firmware state under controlled lighting, frame rate and warm-up.
# This sends GETs only. The labels intentionally describe conditions rather
# than assigning units that the firmware ABI has not proved.
# ============================================================================
if wants readback-profile; then
    step "readback-profile: characterising raw firmware values"
    log_section "SECTION readback-profile"

    [ -n "$DEVICE" ] || wait_for_device || die "no video node to stream from"
    DEBUGFS_DEVICE="/sys/kernel/debug/facetimehd/${SLOT}"
    if [ ! -d "$DEBUGFS_DEVICE" ]; then
        result SKIP profile.debugfs \
            "debugfs device directory is unavailable (mount debugfs first)"
    elif [ "$INTERACTIVE" != 1 ]; then
        result SKIP profile.interactive \
            "lighting profile needs a person (--no-interactive was selected)"
    else
        profile_snapshot() {
            local label="$1" node value
            shift
            for node in "$@"; do
                if value="$(cat "$DEBUGFS_DEVICE/$node" 2>>"$REPORT")"; then
                    result INFO "profile.$label.$node" "$value"
                else
                    result FAIL "profile.$label.$node" "GET failed"
                fi
            done
        }

        profile_prompt() {
            printf '\n%s\nPress Enter when ready: ' "$1"
            read -r _profile_reply
            sleep "$PROFILE_SETTLE_SECS"
        }

        v4l2-ctl --device "$DEVICE" --set-parm=30 >>"$REPORT" 2>&1 ||
            result WARN profile.fps30 "could not request 30 fps; using current rate"
        if [ "$(cat /sys/module/$MODULE_NAME/parameters/runtime_pm 2>/dev/null)" = Y ]; then
            info "Waiting ${IDLE_WAIT}s for a cold runtime-resume baseline."
            sleep "$IDLE_WAIT"
        fi
        dmesg_mark
        v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=100000 \
                 --stream-to=/dev/null >>"$REPORT" 2>&1 &
        STREAM_PID=$!
        sleep 2
        if ! kill -0 "$STREAM_PID" 2>/dev/null; then
            result FAIL profile.stream30 "30 fps profile stream exited"
        else
            profile_snapshot ambient30 \
                sensor_temperature_raw awb_cct_raw ae_bias_raw \
                ae_gain_cap_raw ae_gain_cap_min_raw \
                ae_integration_time_max_raw \
                ae_sensor_integration_time_min_raw \
                ae_sensor_integration_time_max_raw ae_metering_mode_raw

            profile_prompt \
                "Uncover the camera and brightly illuminate the scene with a neutral/white light."
            profile_snapshot bright30 awb_cct_raw ae_bias_raw \
                ae_gain_cap_raw ae_gain_cap_min_raw \
                ae_integration_time_max_raw

            profile_prompt \
                "Cover the camera completely so the frame is as dark as possible."
            profile_snapshot dark30 awb_cct_raw ae_bias_raw ae_gain_cap_raw \
                ae_gain_cap_min_raw ae_integration_time_max_raw

            profile_prompt \
                "Uncover it and illuminate the scene with a warm/yellow light."
            profile_snapshot warm_light awb_cct_raw ae_bias_raw

            profile_prompt \
                "Now illuminate the same scene with a cool/blue-white light."
            profile_snapshot cool_light awb_cct_raw ae_bias_raw

            profile_prompt \
                "Return to ordinary room lighting for the warm-up measurement."
            info "Keeping the stream open for ${PROFILE_WARMUP_SECS}s."
            sleep "$PROFILE_WARMUP_SECS"
            profile_snapshot warmed30 sensor_temperature_raw awb_cct_raw \
                ae_gain_cap_raw ae_integration_time_max_raw
        fi
        kill "$STREAM_PID" 2>/dev/null || true
        wait "$STREAM_PID" 2>/dev/null || true
        STREAM_PID=""

        if v4l2-ctl --device "$DEVICE" --set-parm=15 >>"$REPORT" 2>&1; then
            v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=100000 \
                     --stream-to=/dev/null >>"$REPORT" 2>&1 &
            STREAM_PID=$!
            sleep "$PROFILE_SETTLE_SECS"
            if kill -0 "$STREAM_PID" 2>/dev/null; then
                profile_snapshot ambient15 ae_bias_raw ae_gain_cap_raw \
                    ae_gain_cap_min_raw ae_integration_time_max_raw \
                    ae_sensor_integration_time_min_raw \
                    ae_sensor_integration_time_max_raw
            else
                result FAIL profile.stream15 "15 fps profile stream exited"
            fi
            kill "$STREAM_PID" 2>/dev/null || true
            wait "$STREAM_PID" 2>/dev/null || true
            STREAM_PID=""
        else
            result SKIP profile.fps15 "driver rejected a 15 fps request"
        fi
        v4l2-ctl --device "$DEVICE" --set-parm=30 >>"$REPORT" 2>&1 || true

        if dmesg_since | grep -Eqi \
                'firmware stopped responding|failed to stop firmware channel|unknown tag|IOMMU.*fault|DMAR:.*fault'; then
            result FAIL profile.post_faults \
                "firmware, teardown, or DMA fault followed profiling"
        else
            result PASS profile.post_faults \
                "profiling left streaming and teardown fault-free"
        fi
        unset -f profile_snapshot profile_prompt
    fi
fi

# ============================================================================
# Section: roundtrips (opt-in, writes exact current values only)
#
# Each write accepts only "same". The kernel performs GET -> SET(current) -> GET
# and rejects a changed result. The runner starts and tears down a fresh stream,
# captures again, and exercises runtime resume after every individual setter.
# ============================================================================
if wants roundtrips; then
    step "roundtrips: same-value GET/SET/GET validation"
    log_section "SECTION roundtrips"

    [ -n "$DEVICE" ] || wait_for_device || die "no video node to stream from"
    DEBUGFS_DEVICE="/sys/kernel/debug/facetimehd/${SLOT}"
    if [ ! -d "$DEBUGFS_DEVICE" ]; then
        result SKIP roundtrips.debugfs \
            "debugfs device directory is unavailable (mount debugfs first)"
    elif [ "$INTERACTIVE" = 1 ] &&
         ! confirm "Issue same-value firmware setters one at a time?"; then
        result SKIP roundtrips.confirm "operator declined setter testing"
    else
        for action in $ROUNDTRIPS; do
            action_failed=0
            case "$action" in
                ae_bias)
                    roundtrip_node=roundtrip_ae_bias
                    readback_node=ae_bias_raw ;;
                ae_metering_mode)
                    roundtrip_node=roundtrip_ae_metering_mode
                    readback_node=ae_metering_mode_raw ;;
                ae_integration_time_max)
                    roundtrip_node=roundtrip_ae_integration_time_max
                    readback_node=ae_integration_time_max_raw ;;
                ae_gain_cap)
                    roundtrip_node=roundtrip_ae_gain_cap
                    readback_node=ae_gain_cap_raw ;;
                ae_gain_cap_min)
                    roundtrip_node=roundtrip_ae_gain_cap_min
                    readback_node=ae_gain_cap_min_raw ;;
                *) die "Unknown ROUNDTRIPS item: $action" ;;
            esac

            step "roundtrip: $action"
            log_section "ROUNDTRIP $action"
            dmesg_mark
            v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=100000 \
                     --stream-to=/dev/null >>"$REPORT" 2>&1 &
            STREAM_PID=$!
            sleep 2
            if ! kill -0 "$STREAM_PID" 2>/dev/null; then
                result FAIL "roundtrip.$action.stream" \
                    "stream exited before the setter"
                STREAM_PID=""
                break
            fi

            before="$(cat "$DEBUGFS_DEVICE/$readback_node" 2>>"$REPORT")" || {
                result FAIL "roundtrip.$action.before" "initial GET failed"
                kill "$STREAM_PID" 2>/dev/null || true
                wait "$STREAM_PID" 2>/dev/null || true
                STREAM_PID=""
                break
            }
            result INFO "roundtrip.$action.armed" \
                "about to SET the current value: $before"
            sync -f "$REPORT"
            sync -f "$REPORT.results"

            if ! printf 'same\n' >"$DEBUGFS_DEVICE/$roundtrip_node"; then
                result FAIL "roundtrip.$action.set" \
                    "same-value kernel round trip failed"
                kill "$STREAM_PID" 2>/dev/null || true
                wait "$STREAM_PID" 2>/dev/null || true
                STREAM_PID=""
                break
            fi

            after="$(cat "$DEBUGFS_DEVICE/$readback_node" 2>>"$REPORT")" || {
                result FAIL "roundtrip.$action.after" "final GET failed"
                kill "$STREAM_PID" 2>/dev/null || true
                wait "$STREAM_PID" 2>/dev/null || true
                STREAM_PID=""
                break
            }
            if [ "$before" != "$after" ]; then
                result FAIL "roundtrip.$action.value" \
                    "value changed: before '$before', after '$after'"
                action_failed=1
            else
                result PASS "roundtrip.$action.value" \
                    "GET/SET/GET remained $after"
            fi
            if kill -0 "$STREAM_PID" 2>/dev/null; then
                result PASS "roundtrip.$action.live" \
                    "original stream remained alive"
            else
                result FAIL "roundtrip.$action.live" \
                    "stream exited after the setter"
                action_failed=1
            fi
            kill "$STREAM_PID" 2>/dev/null || true
            wait "$STREAM_PID" 2>/dev/null || true
            STREAM_PID=""

            if capture_ok 10; then
                result PASS "roundtrip.$action.restart" \
                    "capture works after STREAMOFF and restart"
            else
                result FAIL "roundtrip.$action.restart" \
                    "capture failed after stream restart"
                action_failed=1
            fi

            if [ "$(cat /sys/module/$MODULE_NAME/parameters/runtime_pm 2>/dev/null)" = Y ]; then
                sleep "$IDLE_WAIT"
                if capture_ok 10; then
                    result PASS "roundtrip.$action.runtime" \
                        "capture works after an idle runtime cycle"
                else
                    result FAIL "roundtrip.$action.runtime" \
                        "capture failed after an idle runtime cycle"
                    action_failed=1
                fi
            else
                result SKIP "roundtrip.$action.runtime" \
                    "runtime_pm is disabled"
            fi

            dmesg_driver >>"$REPORT"
            if dmesg_since | grep -Eqi \
                    'firmware stopped responding|failed to stop firmware channel|unknown tag|IOMMU.*fault|DMAR:.*fault|channel stop failed'; then
                result FAIL "roundtrip.$action.faults" \
                    "firmware, teardown, or DMA fault followed the setter"
                action_failed=1
            else
                result PASS "roundtrip.$action.faults" \
                    "no firmware, teardown, IOMMU, or DMAR faults"
            fi
            sync -f "$REPORT"
            sync -f "$REPORT.results"
            if [ "$action_failed" -ne 0 ]; then
                warn "Stopping before the next setter because $action failed."
                break
            fi
        done
    fi
fi

# ============================================================================
# Section: metering-modes (opt-in, bounded mutation)
#
# The firmware dispatcher proves that only modes 0..3 exist, and the exact
# current-value write has passed hardware validation. This next stage changes
# one mode at a time through a fixed-token debugfs endpoint. A fresh stream is
# used per mode; its original mode is restored while that stream is still live.
# The retained frames and spatial luma measurements establish whether those
# four firmware values honestly map to the standard V4L2 metering menu.
# ============================================================================
if wants metering-modes; then
    step "metering-modes: bounded AE metering mutation"
    log_section "SECTION metering-modes"

    [ -n "$DEVICE" ] || wait_for_device || die "no video node to stream from"
    DEBUGFS_DEVICE="/sys/kernel/debug/facetimehd/${SLOT}"
    if [ "$METERING_RESTART_AE" = 1 ]; then
        metering_node="$DEBUGFS_DEVICE/test_ae_metering_mode_restart"
        metering_sequence="stop AE, set mode, restart AE"
    else
        metering_node="$DEBUGFS_DEVICE/test_ae_metering_mode"
        metering_sequence="set mode while AE remains live"
    fi
    metering_readback="$DEBUGFS_DEVICE/ae_metering_mode_raw"

    if [ ! -w "$metering_node" ] || [ ! -r "$metering_readback" ]; then
        result SKIP metering.debugfs \
            "bounded metering test nodes are unavailable"
    elif [ "$INTERACTIVE" != 1 ]; then
        result SKIP metering.interactive \
            "metering semantics need a fixed high-contrast scene"
    elif ! confirm "Test only firmware metering modes 0, 1, 2 and 3, restoring the original after each?"; then
        result SKIP metering.confirm "operator declined bounded setter testing"
    else
        # The luma parser below wants a packed frame; the driver's default is
        # NV12. The fourcc check that follows stays as the real guard, since it
        # reads back what the device ended up with rather than what was asked.
        use_packed_format || result WARN metering.format \
            "could not select a packed format for the luma parser"
        fmt_text="$(v4l2-ctl --device "$DEVICE" --get-fmt-video 2>>"$REPORT")"
        dimensions="$(printf '%s\n' "$fmt_text" | sed -n \
            's/^[[:space:]]*Width\/Height[[:space:]]*:[[:space:]]*\([0-9][0-9]*\)\/\([0-9][0-9]*\).*/\1 \2/p' | head -1)"
        read -r metering_width metering_height <<<"$dimensions"
        metering_fourcc="$(printf '%s\n' "$fmt_text" | sed -n \
            "s/^[[:space:]]*Pixel Format[[:space:]]*:[[:space:]]*'\([^']*\)'.*/\1/p" | head -1)"
        metering_frame_size="$(printf '%s\n' "$fmt_text" | sed -n \
            's/^[[:space:]]*Size Image[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"

        if [ -z "$metering_width" ] || [ -z "$metering_height" ] ||
           [ -z "$metering_frame_size" ]; then
            result FAIL metering.format "could not parse capture dimensions"
        elif [ "$metering_fourcc" != YUYV ]; then
            result SKIP metering.format \
                "luma parser does not support $metering_fourcc"
        else
            METERING_DIR="$(mktemp -d -p /tmp facetimehd-metering.XXXXXXXX)"
            result INFO metering.frames \
                "retaining raw mode captures in $METERING_DIR"
            result INFO metering.sequence "$metering_sequence"
            info "Set up one stationary, high-contrast scene: put a bright"
            info "white target exactly in the middle of the image with a much"
            info "darker surround. Make the target fill about one quarter of"
            info "the image width and height, without clipping to solid white."
            info "Keep the camera, target and lighting fixed."
            printf 'Press Enter when ready: '
            read -r _metering_reply

            v4l2-ctl --device "$DEVICE" --set-parm=30 >>"$REPORT" 2>&1 ||
                result WARN metering.fps "could not request 30 fps"

            # Mode 3 first is the known startup baseline. Each following run
            # starts a new channel, which independently resets firmware to 3.
            for metering_mode in 3 0 1 2; do
                action_failed=0
                metering_raw="$METERING_DIR/mode${metering_mode}.raw"
                : >"$metering_raw"
                dmesg_mark

                # v4l2-ctl's sleep counter includes --stream-skip buffers,
                # although its stream-count does not. Pause only after both
                # the settling frames and retained frames have been dequeued.
                metering_sleep_count=$(( METERING_SETTLE_FRAMES +
                                          METERING_CAPTURE_FRAMES ))
                metering_mode_wait=$(( (metering_sleep_count + 29) / 30 + 3 ))
                if [ "$metering_mode_wait" -lt "$METERING_WAIT_SECS" ]; then
                    metering_mode_wait="$METERING_WAIT_SECS"
                fi

                v4l2-ctl --device "$DEVICE" --stream-mmap \
                    --stream-count=100000 \
                    --stream-skip="$METERING_SETTLE_FRAMES" \
                    --stream-sleep="count=${metering_sleep_count},sleep=0,mode=0" \
                    --stream-to="$metering_raw" >>"$REPORT" 2>&1 &
                STREAM_PID=$!

                metering_original=""
                for _metering_try in $(seq 1 40); do
                    if metering_original="$(cat "$metering_readback" 2>>"$REPORT")"; then
                        case "$metering_original" in
                            0|1|2|3) break ;;
                            *) metering_original="" ;;
                        esac
                    fi
                    sleep 0.1
                done

                if [ -z "$metering_original" ]; then
                    result FAIL "metering.mode${metering_mode}.start" \
                        "stream never exposed a valid original mode"
                    action_failed=1
                else
                    METERING_RESTORE_NODE="$metering_node"
                    METERING_ORIGINAL="$metering_original"
                    result INFO "metering.mode${metering_mode}.armed" \
                        "original=$metering_original; about to request mode $metering_mode"
                    sync -f "$REPORT"
                    sync -f "$REPORT.results"

                    if printf 'mode%s\n' "$metering_mode" >"$metering_node"; then
                        metering_after="$(cat "$metering_readback" 2>>"$REPORT" || true)"
                        if [ "$metering_after" = "$metering_mode" ]; then
                            result PASS "metering.mode${metering_mode}.set" \
                                "firmware readback is $metering_after"
                        else
                            result FAIL "metering.mode${metering_mode}.set" \
                                "requested $metering_mode, read back '$metering_after'"
                            action_failed=1
                        fi
                    else
                        result FAIL "metering.mode${metering_mode}.set" \
                            "bounded firmware setter failed"
                        action_failed=1
                    fi
                fi

                sleep "$metering_mode_wait"
                if kill -0 "$STREAM_PID" 2>/dev/null; then
                    result PASS "metering.mode${metering_mode}.live" \
                        "stream remained alive through settle and capture"
                    metering_steady="$(cat "$metering_readback" 2>>"$REPORT" || true)"
                    if [ "$metering_steady" != "$metering_mode" ]; then
                        result FAIL "metering.mode${metering_mode}.steady" \
                            "mode changed before restore: '$metering_steady'"
                        action_failed=1
                    else
                        result PASS "metering.mode${metering_mode}.steady" \
                            "mode remained $metering_steady until restore"
                    fi
                else
                    result FAIL "metering.mode${metering_mode}.live" \
                        "capture process exited before restoration"
                    action_failed=1
                fi

                metering_restored=""
                if [ -n "$metering_original" ] &&
                   kill -0 "$STREAM_PID" 2>/dev/null &&
                   printf 'mode%s\n' "$metering_original" >"$metering_node"; then
                    metering_restored="$(cat "$metering_readback" 2>>"$REPORT" || true)"
                fi
                if [ -n "$metering_original" ] &&
                   [ "$metering_restored" = "$metering_original" ]; then
                    result PASS "metering.mode${metering_mode}.restore" \
                        "restored original mode $metering_original before STREAMOFF"
                    METERING_RESTORE_NODE=""
                    METERING_ORIGINAL=""
                else
                    result FAIL "metering.mode${metering_mode}.restore" \
                        "could not verify original mode restoration"
                    action_failed=1
                fi

                kill "$STREAM_PID" 2>/dev/null || true
                wait "$STREAM_PID" 2>/dev/null || true
                STREAM_PID=""
                METERING_RESTORE_NODE=""
                METERING_ORIGINAL=""

                metering_bytes="$(stat -c %s "$metering_raw" 2>/dev/null || echo 0)"
                metering_complete=$(( metering_bytes / metering_frame_size ))
                if [ "$metering_complete" -gt 0 ] &&
                   metering_metrics="$(frame_luma_metrics "$metering_raw" \
                       "$metering_frame_size" "$metering_width" \
                       "$metering_height")"; then
                    result INFO "metering.mode${metering_mode}.luma" \
                        "$metering_metrics frames=$metering_complete"
                    if [ "$metering_mode" -eq 3 ]; then
                        metering_spot="$(printf '%s\n' "$metering_metrics" |
                            sed -n 's/.*spot=\([0-9.][0-9.]*\).*/\1/p')"
                        metering_outer="$(printf '%s\n' "$metering_metrics" |
                            sed -n 's/.*outer=\([0-9.][0-9.]*\).*/\1/p')"
                        if [ -n "$metering_spot" ] &&
                           [ -n "$metering_outer" ] &&
                           awk -v s="$metering_spot" -v o="$metering_outer" \
                               'BEGIN { exit !(s >= o + 20 && s < 235) }'; then
                            result PASS metering.scene \
                                "bright central spot is distinct and unclipped ($metering_spot vs outer $metering_outer)"
                        else
                            result FAIL metering.scene \
                                "central spot must be 20+ luma above outer and below 235 (spot=$metering_spot outer=$metering_outer); reposition or dim target"
                            action_failed=1
                        fi
                    fi
                else
                    result FAIL "metering.mode${metering_mode}.luma" \
                        "no complete frame available for measurement"
                    action_failed=1
                fi

                if capture_ok 10; then
                    result PASS "metering.mode${metering_mode}.restart" \
                        "capture works after restore and STREAMOFF"
                else
                    result FAIL "metering.mode${metering_mode}.restart" \
                        "capture failed after restore and STREAMOFF"
                    action_failed=1
                fi

                if [ "$(cat /sys/module/$MODULE_NAME/parameters/runtime_pm 2>/dev/null)" = Y ]; then
                    sleep "$IDLE_WAIT"
                    if capture_ok 10; then
                        result PASS "metering.mode${metering_mode}.runtime" \
                            "capture works after an idle runtime cycle"
                    else
                        result FAIL "metering.mode${metering_mode}.runtime" \
                            "capture failed after an idle runtime cycle"
                        action_failed=1
                    fi
                else
                    result SKIP "metering.mode${metering_mode}.runtime" \
                        "runtime_pm is disabled"
                fi

                dmesg_driver >>"$REPORT"
                if dmesg_since | grep -Eqi \
                        'firmware stopped responding|failed to stop firmware channel|unknown tag|IOMMU.*fault|DMAR:.*fault|channel stop failed'; then
                    result FAIL "metering.mode${metering_mode}.faults" \
                        "firmware, teardown, or DMA fault followed the mutation"
                    action_failed=1
                else
                    result PASS "metering.mode${metering_mode}.faults" \
                        "no firmware, teardown, IOMMU, or DMAR faults"
                fi
                sync -f "$REPORT"
                sync -f "$REPORT.results"

                if [ "$action_failed" -ne 0 ]; then
                    warn "Stopping before the next metering mode."
                    break
                fi
            done
            result INFO metering.interpretation \
                "compare full/spot/centre/outer luma across modes; semantics are not assigned automatically"
        fi
    fi
fi

# ============================================================================
# Section: framerate
# DOWNSTREAM.md - "Frame rate"
#
# S_PARM programs the ISP's AE frame-rate window, which the sensor follows.
# This checks that each requested rate is reported back by G_PARM and actually
# delivered, that S_PARM is refused while streaming (the window only reaches the
# firmware at channel start), and that a STREAMOFF at the slowest rate returns
# every buffer.
#
# The rate is measured from the difference between a short and a long capture
# rather than from one capture's duration. v4l2-ctl spends roughly two seconds
# opening the node, allocating buffers and reaching the first frame, and at
# 30 fps that fixed cost is a third of a six-second measurement: it has to be
# subtracted, not tolerated.
# ============================================================================
if wants framerate; then
    step "framerate: are requested frame rates actually delivered"
    log_section "SECTION framerate"

    [ -n "$DEVICE" ] || wait_for_device || true
    if [ -z "$DEVICE" ]; then
        result SKIP framerate "no video node"
    elif ! clock_sane; then
        # Everything below is a duration; without a millisecond clock the only
        # honest result is no result.
        result FAIL framerate.clock \
            "no usable millisecond clock, so no frame rate can be measured"
    else
        slowest_rate=""
        for rate in $FRAMERATE_RATES; do
            [ "$rate" -gt 30 ] && rate=30
            expect="$(awk -v r="$rate" 'BEGIN{printf "%.3f", r}')"
            if [ -z "$slowest_rate" ] || [ "$rate" -lt "$slowest_rate" ]; then
                slowest_rate="$rate"
            fi

            log_section "FRAMERATE ${rate} fps"
            dmesg_mark

            if ! v4l2-ctl --device "$DEVICE" --set-parm="$rate" >>"$REPORT" 2>&1; then
                result FAIL "framerate.$rate.set" "S_PARM was rejected"
                continue
            fi
            got="$(v4l2-ctl --device "$DEVICE" --get-parm 2>/dev/null |
                   sed -n 's/^[[:space:]]*Frames per second:[[:space:]]*\([0-9.]*\).*/\1/p' |
                   head -1)"
            if [ -z "$got" ]; then
                result FAIL "framerate.$rate.readback" "G_PARM printed no rate"
                continue
            fi
            if awk -v g="$got" -v e="$expect" 'BEGIN{d=g-e; if(d<0)d=-d; exit !(d < 0.01)}'; then
                result PASS "framerate.$rate.readback" \
                    "G_PARM reports $got fps"
            else
                result FAIL "framerate.$rate.readback" \
                    "G_PARM reports $got fps, expected $expect"
                continue
            fi

            # Warm-up, discarded. With runtime PM on, the first capture after
            # an idle gap pays for a DDR retrain and a firmware reload. That
            # cost lands on whichever capture happens to be first, and the
            # subtraction below cannot remove a cost that only one of the two
            # paid - it would report a rate faster than the camera delivered.
            capture_ok 4 "$rate" || true

            # Two captures, both at this rate; the difference between them is
            # free of v4l2-ctl's fixed start-up cost.
            short_frames=$(( rate * 2 ))
            [ "$short_frames" -ge 4 ] || short_frames=4
            extra_frames=$(( rate * FRAMERATE_SECS ))
            [ "$extra_frames" -ge 4 ] || extra_frames=4
            long_frames=$(( short_frames + extra_frames ))

            # Capture the status explicitly. After a failed `if cmd`, `$?` is
            # the status of the if statement, which is zero - reading it there
            # would silently turn every starved capture into "some other error".
            short_rc=0
            short_ms="$(timed_capture "$short_frames" "$rate")" || short_rc=$?
            long_rc=0
            if [ "$short_rc" -eq 0 ]; then
                long_ms="$(timed_capture "$long_frames" "$rate")" || long_rc=$?
            fi
            if [ "$short_rc" -ne 0 ] || [ "$long_rc" -ne 0 ]; then
                if [ "$short_rc" -eq 124 ] || [ "$long_rc" -eq 124 ]; then
                    result FAIL "framerate.$rate.capture" \
                        "the stream starved: no buffers arrived before the timeout"
                else
                    result FAIL "framerate.$rate.capture" \
                        "capture failed (status ${short_rc}/${long_rc})"
                fi
                continue
            fi
            log "frames $short_frames/$long_frames took ${short_ms}/${long_ms} ms"

            if [ "$long_ms" -le "$short_ms" ]; then
                result WARN "framerate.$rate.rate" \
                    "the longer capture did not take longer (${short_ms} vs ${long_ms} ms) - unusable timing"
            else
                measured="$(awk -v n="$extra_frames" -v t="$(( long_ms - short_ms ))" \
                            'BEGIN{printf "%.2f", n * 1000 / t}')"
                if awk -v m="$measured" -v e="$expect" -v tol="$FRAMERATE_TOLERANCE" \
                       'BEGIN{d=m-e; if(d<0)d=-d; exit !(d <= e*tol/100)}'; then
                    result PASS "framerate.$rate.rate" \
                        "delivered $measured fps against an expected $expect"
                else
                    result FAIL "framerate.$rate.rate" \
                        "delivered $measured fps, expected $expect +/-${FRAMERATE_TOLERANCE}%"
                fi
            fi

            # A coarse bunching probe, not a jitter measurement: N frames
            # cannot legitimately arrive faster than (N-1)/rate, so a short
            # capture finishing well inside that means the driver released a
            # burst rather than spacing frames out. v4l2-ctl queues four buffers, so
            # a burst can never be large - this catches gross misbehaviour, not
            # small timing noise.
            floor_ms="$(awk -v n="$short_frames" -v e="$expect" \
                        'BEGIN{printf "%d", (n - 1) * 1000 / e * 0.7}')"
            if [ "$short_ms" -ge "$floor_ms" ]; then
                result PASS "framerate.$rate.spacing" \
                    "$short_frames frames took ${short_ms} ms, at or above the ${floor_ms} ms floor"
            else
                result WARN "framerate.$rate.spacing" \
                    "$short_frames frames took only ${short_ms} ms against a ${floor_ms} ms floor - frames may be arriving in bursts"
            fi

            dmesg_driver >>"$REPORT"
            if faults_present; then
                result FAIL "framerate.$rate.faults" \
                    "firmware, buffer or DMA fault during capture"
            else
                result PASS "framerate.$rate.faults" \
                    "no firmware, buffer, IOMMU or DMAR faults"
            fi
        done

        result INFO framerate.jitter \
            "mean rate only; per-frame spacing is not measured by this test"

        # STREAMOFF at the slowest rate, where buffers sit with the ISP longest,
        # and S_PARM while streaming, which the driver must refuse.
        if [ -n "$slowest_rate" ]; then
            log_section "FRAMERATE streamoff at ${slowest_rate} fps"
            v4l2-ctl --device "$DEVICE" --set-parm="$slowest_rate" >>"$REPORT" 2>&1 || true
            dmesg_mark
            v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=100000 \
                     --stream-to=/dev/null >>"$REPORT" 2>&1 &
            STREAM_PID=$!
            sleep "$FRAMERATE_OFF_SECS"
            if kill -0 "$STREAM_PID" 2>/dev/null; then
                if v4l2-ctl --device "$DEVICE" --set-parm=30 >>"$REPORT" 2>&1 &&
                   ! v4l2-ctl --device "$DEVICE" --get-parm 2>/dev/null |
                       grep -q "Frames per second:[[:space:]]*${slowest_rate}\.0"; then
                    result FAIL framerate.busy \
                        "S_PARM changed the rate of a running stream instead of refusing"
                else
                    result PASS framerate.busy \
                        "S_PARM was refused while streaming"
                fi
                kill "$STREAM_PID" 2>/dev/null || true
                wait "$STREAM_PID" 2>/dev/null || true
                STREAM_PID=""
                sleep 2
                dmesg_driver >>"$REPORT"
                if faults_present; then
                    result FAIL framerate.streamoff \
                        "STREAMOFF at ${slowest_rate} fps left a buffer, channel or DMA fault"
                else
                    result PASS framerate.streamoff \
                        "STREAMOFF at ${slowest_rate} fps returned every buffer cleanly"
                fi
                if capture_ok 10; then
                    result PASS framerate.streamoff.restart \
                        "capture works again after the mid-stream STREAMOFF"
                else
                    result FAIL framerate.streamoff.restart \
                        "capture failed after the mid-stream STREAMOFF"
                fi
            else
                result FAIL framerate.streamoff \
                    "the stream exited on its own before STREAMOFF"
                STREAM_PID=""
            fi
        fi

        v4l2-ctl --device "$DEVICE" --set-parm=30 >>"$REPORT" 2>&1 || true
    fi
fi

# ============================================================================
# Section: crop
# DOWNSTREAM.md - "Cropping"
#
# The open question is whether the ISP honours a non-zero origin at all, and a
# capture that merely succeeds does not answer it: a rectangle that is silently
# ignored still produces perfectly good frames. So this compares the *shape* of
# two frames taken through rectangles at opposite corners of the sensor array.
# If the origin does nothing, both frames show the same scene.
#
# Alignment stricter than eight pixels and whether the scaler will upscale are
# the other two open items and are deliberately absent: the driver rounds the
# rectangle and refuses to go below the output size, so neither question is
# reachable through this ABI. What this section can do is record exactly what
# the driver did with a misaligned request, so a future firmware experiment has
# the baseline.
# ============================================================================
if wants crop; then
    step "crop: non-zero rectangles and whether they move the picture"
    log_section "SECTION crop"

    [ -n "$DEVICE" ] || wait_for_device || true
    if [ -z "$DEVICE" ]; then
        result SKIP crop "no video node"
    else
        crop_orig_wh="$(fmt_field 'Width\/Height')"
        crop_orig_fmt="$(fmt_field 'Pixel Format' | sed -n "s/.*'\\([A-Z0-9]*\\)'.*/\\1/p")"
        crop_bounds="$(v4l2-ctl --device "$DEVICE" \
                       --get-selection=target=crop_bounds 2>/dev/null |
                       sed -n 's/.*Width \([0-9]*\), Height \([0-9]*\).*/\1 \2/p' | head -1)"
        log "original format: $crop_orig_wh $crop_orig_fmt; sensor bounds: ${crop_bounds:-unknown}"

        if [ -z "$crop_bounds" ]; then
            result SKIP crop.bounds "G_SELECTION did not report crop bounds"
        else
            sensor_w="${crop_bounds%% *}"
            sensor_h="${crop_bounds##* }"

            v4l2-ctl --device "$DEVICE" \
                --set-fmt-video="width=$CROP_WIDTH,height=$CROP_HEIGHT,pixelformat=YUYV" \
                >>"$REPORT" 2>&1 || true
            out_wh="$(fmt_field 'Width\/Height')"
            out_w="${out_wh%%/*}"
            out_h="${out_wh##*/}"
            frame_size=$(( out_w * 2 * out_h ))
            result INFO crop.output \
                "moving the crop over a ${sensor_w}x${sensor_h} array with a ${out_w}x${out_h} output"

            if [ "$INTERACTIVE" = 1 ]; then
                info "Point the camera at a still, unevenly lit scene - a window on"
                info "one side, a wall on the other. Keep it still, then press Enter."
                read -r _ || true
            fi

            # left top width height, and whether an exact readback is expected.
            #
            # The corner rectangles sit flush with the far edges of the array,
            # so they stay on the sensor and must read back exactly and stream.
            # A starvation is a FAIL: the firmware only starves on a window
            # that leaves the array, and the driver never sends one.
            far_left=$(( sensor_w - out_w ))
            far_top=$(( sensor_h - out_h ))
            crop_sig_tl=""
            crop_sig_br=""
            crop_far_label=""
            # Order matters. A starved rectangle wedges the channel, so every
            # rectangle that answers a question comes first and the two known
            # pathological corners come last. midoffset exists because the
            # origin comparison needs a second rectangle of the SAME size at a
            # different origin - comparing against the full array would differ
            # in scale as well, which proves nothing about the origin - and
            # because both corners have now starved in different runs.
            mid_left="$(( ((sensor_w - out_w) / 2) & ~7 ))"
            mid_top=$(( (sensor_h - out_h) / 2 ))
            for spec in "0 0 $sensor_w $sensor_h exact full" \
                        "8 8 $out_w $out_h exact topleft" \
                        "$mid_left $mid_top $out_w $out_h exact midoffset" \
                        "4 5 $out_w $out_h rounded misaligned" \
                        "$far_left $far_top $out_w $out_h exact bottomright" \
                        "$far_left 0 $out_w $out_h exact cornerflush" \
                        "$(( far_left + 64 )) $(( far_top + 8 )) $out_w $out_h rounded pastedge"; do
                read -r want_l want_t want_w want_h exactness label <<<"$spec"

                dmesg_mark
                if ! v4l2-ctl --device "$DEVICE" \
                        --set-selection="target=crop,left=$want_l,top=$want_t,width=$want_w,height=$want_h" \
                        >>"$REPORT" 2>&1; then
                    result FAIL "crop.$label.set" \
                        "S_SELECTION rejected ${want_w}x${want_h}+${want_l}+${want_t}"
                    continue
                fi
                got_crop="$(current_crop)"
                if [ -z "$got_crop" ]; then
                    result FAIL "crop.$label.readback" "G_SELECTION printed nothing"
                    continue
                fi
                if [ "$exactness" = exact ]; then
                    if [ "$got_crop" = "$want_l $want_t $want_w $want_h" ]; then
                        result PASS "crop.$label.readback" \
                            "read back exactly as ${want_w}x${want_h}+${want_l}+${want_t}"
                    else
                        result FAIL "crop.$label.readback" \
                            "asked for ${want_w}x${want_h}+${want_l}+${want_t}, got '$got_crop'"
                    fi
                else
                    # Expected to be adjusted. The value is the record, not a verdict:
                    # it is the driver's rounding, and says nothing about what the
                    # ISP would have accepted.
                    result INFO "crop.$label.readback" \
                        "requested ${want_w}x${want_h}+${want_l}+${want_t}, driver stored '$got_crop'"
                fi

                # Bounded: a rectangle the ISP accepts and then delivers no
                # buffers for is an observed failure on the MacBookAir7,2, and
                # an unbounded capture there waits in vb2_wait_for_done_vb for
                # as long as the run lasts.
                capture_file="/tmp/facetimehd-crop-$label.raw"
                rm -f "$capture_file"
                crop_rc=0
                timeout -s TERM "$(capture_timeout_secs 15 30)" \
                    v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=15 \
                             --stream-to="$capture_file" >>"$REPORT" 2>&1 || crop_rc=$?
                # v4l2-ctl exits 0 even when STREAMON fails - it reports
                # "VIDIOC_STREAMON returned -1" on stdout and still returns
                # success - so an exit status alone once marked two empty
                # captures as passes. The file is the evidence: no complete
                # frame means no capture, whatever the status said.
                crop_bytes="$(stat -c %s "$capture_file" 2>/dev/null || echo 0)"
                if [ "$crop_rc" -eq 0 ] && [ "$crop_bytes" -lt "$frame_size" ]; then
                    result FAIL "crop.$label.capture" \
                        "v4l2-ctl reported success but wrote $crop_bytes bytes, less than one $frame_size-byte frame (STREAMON likely failed)"
                    continue
                fi
                if [ "$crop_rc" -eq 0 ]; then
                    result PASS "crop.$label.capture" "captured through this rectangle"
                elif [ "$crop_rc" -eq 124 ]; then
                    result FAIL "crop.$label.starved" \
                        "the ISP accepted ${want_w}x${want_h}+${want_l}+${want_t} and then delivered no buffers at all"
                    # A starved rectangle leaves the channel wedged: every
                    # later STREAMON returns EIO until the firmware is
                    # reloaded. Without this, one bad rectangle silently
                    # invalidates every rectangle after it. An idle gap lets
                    # runtime PM tear the ISP down and rebuild it; where
                    # runtime PM is off there is nothing to wait for and the
                    # remaining results are reported as untrustworthy.
                    if [ "$(cat /sys/module/$MODULE_NAME/parameters/runtime_pm 2>/dev/null)" = Y ]; then
                        sleep "$IDLE_WAIT"
                        if capture_ok 5; then
                            result INFO "crop.$label.recovered" \
                                "a runtime-PM cycle brought the channel back for the remaining rectangles"
                        else
                            result WARN "crop.$label.recovered" \
                                "the channel did not recover; rectangles after this one are not trustworthy"
                        fi
                    else
                        result WARN "crop.$label.recovered" \
                            "runtime PM is off, so the wedged channel cannot be reset here; rectangles after this one are not trustworthy"
                    fi
                    continue
                else
                    result FAIL "crop.$label.capture" "capture failed through this rectangle"
                    continue
                fi

                sig="$(packed_block_luma "$capture_file" "$frame_size" "$out_w" "$out_h" || true)"
                if [ -n "$sig" ]; then
                    log "block luma [$label]: $sig"
                    # Any far-offset rectangle answers the origin question, so
                    # take whichever one produced a frame. Keying it to
                    # bottomright alone meant a single starved rectangle
                    # skipped the check the section exists for.
                    case "$label" in
                        topleft) crop_sig_tl="$sig" ;;
                        midoffset|bottomright|cornerflush)
                            [ -n "$crop_sig_br" ] || crop_sig_br="$sig"
                            [ -n "$crop_far_label" ] || crop_far_label="$label" ;;
                    esac
                fi

                dmesg_driver >>"$REPORT"
                if faults_present; then
                    result FAIL "crop.$label.faults" \
                        "firmware, buffer or DMA fault with this rectangle"
                fi
            done

            # The actual open question.
            if [ -n "$crop_sig_tl" ] && [ -n "$crop_sig_br" ]; then
                spread_tl="$(block_spread "$crop_sig_tl")"
                spread_br="$(block_spread "$crop_sig_br")"
                shape="$(block_shape_diff "$crop_sig_tl" "$crop_sig_br")"
                log "crop shape difference: $shape (spreads $spread_tl / $spread_br)"
                if awk -v a="$spread_tl" -v b="$spread_br" 'BEGIN{exit !(a < 5 && b < 5)}'; then
                    result WARN crop.origin \
                        "the scene has almost no spatial structure (spreads $spread_tl/$spread_br) - this cannot show whether the origin moved; re-run pointing at something uneven"
                elif awk -v s="$shape" 'BEGIN{exit !(s >= 3)}'; then
                    result PASS crop.origin \
                        "topleft versus $crop_far_label produced different images (shape difference $shape) - the ISP honours a non-zero origin"
                else
                    result WARN crop.origin \
                        "topleft versus $crop_far_label produced near-identical images (shape difference $shape) - either the scene was uniform or the ISP ignored the origin"
                fi
                result INFO crop.frames \
                    "kept /tmp/facetimehd-crop-{full,topleft,bottomright,misaligned}.raw for eyeballing"
            else
                result SKIP crop.origin \
                    "no far-offset rectangle produced a frame to compare against"
            fi
        fi

        # Restore. The crop floor is the output size, so the format goes back
        # first or the default rectangle cannot be re-fitted around it.
        if [ -n "$crop_orig_wh" ] && [ -n "$crop_orig_fmt" ]; then
            v4l2-ctl --device "$DEVICE" \
                --set-fmt-video="width=${crop_orig_wh%%/*},height=${crop_orig_wh##*/},pixelformat=$crop_orig_fmt" \
                >>"$REPORT" 2>&1 || true
        fi
        crop_default="$(v4l2-ctl --device "$DEVICE" \
                        --get-selection=target=crop_default 2>/dev/null |
                        sed -n 's/.*Left \([0-9-]*\), Top \([0-9-]*\), Width \([0-9]*\), Height \([0-9]*\).*/\1,\2,\3,\4/p' |
                        head -1)"
        if [ -n "$crop_default" ]; then
            IFS=, read -r d_l d_t d_w d_h <<<"$crop_default"
            v4l2-ctl --device "$DEVICE" \
                --set-selection="target=crop,left=$d_l,top=$d_t,width=$d_w,height=$d_h" \
                >>"$REPORT" 2>&1 || true
        fi
    fi
fi

# ============================================================================
# Section: crop-geometry (opt-in)
# DOWNSTREAM.md - "Cropping"
#
# CISP_CMD_CH_CROP_SET takes (x, y, width, height). The firmware accepts a
# window that leaves the sensor array and then delivers no frames until it is
# reloaded, so the driver clamps the origin to keep the rectangle on the array.
#
# Each probe sets a rectangle, reads CISP_CMD_CH_CROP_GET from a live stream
# and checks that frames arrive. The first group of crop_raw must equal the
# programmed (x, y, width, height). Rectangles flush with the far edges must
# stream unchanged; ones past the edges must come back clamped to them and
# stream. A starved rectangle is a FAIL, with wedge recovery as a safety net.
#
# It changes no firmware state: crop and format go through the ordinary
# S_SELECTION/S_FMT paths, and every firmware command sent is a GET.
# ============================================================================
if wants crop-geometry; then
    step "crop-geometry: reading the ISP's crop rectangles at and past the array edges"
    log_section "SECTION crop-geometry"

    [ -n "$DEVICE" ] || wait_for_device || true
    DEBUGFS_DEVICE="/sys/kernel/debug/facetimehd/${SLOT}"
    if [ -z "$DEVICE" ]; then
        result SKIP crop-geometry "no video node"
    elif [ ! -r "$DEBUGFS_DEVICE/crop_raw" ]; then
        result SKIP crop-geometry.debugfs \
            "crop_raw is unreadable (mount debugfs and run as root)"
    else
        cg_bounds="$(v4l2-ctl --device "$DEVICE" \
                     --get-selection=target=crop_bounds 2>/dev/null |
                     sed -n 's/.*Width \([0-9]*\), Height \([0-9]*\).*/\1 \2/p' | head -1)"
        cg_default="$(v4l2-ctl --device "$DEVICE" \
                      --get-selection=target=crop_default 2>/dev/null |
                      sed -n 's/.*Left \([0-9-]*\), Top \([0-9-]*\), Width \([0-9]*\), Height \([0-9]*\).*/\1,\2,\3,\4/p' | head -1)"
        cg_orig_wh="$(fmt_field 'Width\/Height')"
        if [ -z "$cg_bounds" ]; then
            result SKIP crop-geometry.bounds "G_SELECTION did not report crop bounds"
        else
            cg_sensor_w="${cg_bounds%% *}"
            cg_sensor_h="${cg_bounds##* }"
            cg_frame_size=0

            # capture_ok() judges by v4l2-ctl's exit status, and v4l2-ctl exits
            # 0 even when VIDIOC_STREAMON fails - which is exactly what a
            # wedged channel does. An earlier run of this section used it and
            # silently reported no wedge while the channel was plainly dead, so
            # health is judged by whether a whole frame arrived.
            cg_capture_ok() {
                local f="/tmp/facetimehd-cropgeom-probe.raw" bytes
                rm -f "$f"
                timeout -s TERM "$(capture_timeout_secs 5 30)" \
                    v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=5 \
                             --stream-to="$f" >>"$REPORT" 2>&1 || true
                bytes="$(stat -c %s "$f" 2>/dev/null || echo 0)"
                rm -f "$f"
                [ "$bytes" -ge "$cg_frame_size" ]
            }

            # Set the output size for a phase and recompute the frame size the
            # health check measures against.
            cg_set_output() {
                v4l2-ctl --device "$DEVICE" \
                    --set-fmt-video="width=$1,height=$2,pixelformat=YUYV" \
                    >>"$REPORT" 2>&1 || true
                local wh; wh="$(fmt_field 'Width\/Height')"
                cg_out_w="${wh%%/*}"
                cg_out_h="${wh##*/}"
                cg_frame_size=$(( cg_out_w * 2 * cg_out_h ))
            }

            # One rectangle: set it, sample crop_raw from a live stream, then
            # check the channel survived. The stream merely existing is enough
            # for the GET - a starved rectangle sits in vb2_wait_for_done_vb
            # with the channel started, which is the case most worth sampling -
            # so frames are counted separately to say which happened.
            cg_probe() {
                local l="$1" t="$2" w="$3" h="$4" label="$5" expect="${6:-exact}"
                local got g_l g_t g_w g_h want cap pid raw bytes flow

                dmesg_mark
                if ! v4l2-ctl --device "$DEVICE" \
                        --set-selection="target=crop,left=$l,top=$t,width=$w,height=$h" \
                        >>"$REPORT" 2>&1; then
                    result FAIL "crop-geometry.$label.set" \
                        "S_SELECTION rejected ${w}x${h}+${l}+${t}"
                    return
                fi
                got="$(current_crop)"
                read -r g_l g_t g_w g_h <<CGEOF
$got
CGEOF
                want="$g_l $g_t $g_w $g_h"
                if [ "$expect" = exact ] && [ "$want" != "$l $t $w $h" ]; then
                    result FAIL "crop-geometry.$label.readback" \
                        "asked for $l $t $w $h, driver stored $want"
                elif [ "$expect" = clamped ] && [ "$want" = "$l $t $w $h" ]; then
                    result FAIL "crop-geometry.$label.readback" \
                        "$l $t $w $h leaves the array but was stored unclamped"
                fi

                cap="/tmp/facetimehd-cropgeom-$label.raw"
                rm -f "$cap"
                v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=100000 \
                         --stream-to="$cap" >>"$REPORT" 2>&1 &
                pid=$!
                sleep 3
                raw=""
                if kill -0 "$pid" 2>/dev/null; then
                    raw="$(tr '\n' '/' < "$DEBUGFS_DEVICE/crop_raw" 2>/dev/null | sed 's|/$||')"
                fi
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                bytes="$(stat -c %s "$cap" 2>/dev/null || echo 0)"
                rm -f "$cap"
                if [ "$bytes" -ge "$cg_frame_size" ]; then
                    flow="streaming"
                else
                    flow="no frames delivered"
                    result FAIL "crop-geometry.$label.starved" \
                        "$want delivered no frames; a rectangle on the array should stream"
                fi

                if [ -z "$raw" ]; then
                    result WARN "crop-geometry.$label" \
                        "requested $want, but the channel was not running to read crop_raw"
                elif [ "${raw%%/*}" = "$want" ]; then
                    result PASS "crop-geometry.$label" \
                        "firmware latched $want ($flow); array group ${raw#*/}"
                else
                    result FAIL "crop-geometry.$label" \
                        "programmed $want, firmware returned $raw ($flow)"
                fi

                # Restore a rectangle known to stream before testing recovery,
                # so this measures the channel and not the geometry just set.
                v4l2-ctl --device "$DEVICE" \
                    --set-selection="target=crop,left=0,top=0,width=$cg_sensor_w,height=$cg_sensor_h" \
                    >>"$REPORT" 2>&1 || true
                if ! cg_capture_ok; then
                    result INFO "crop-geometry.$label.wedged" \
                        "the channel stopped delivering after this rectangle"
                    if [ "$(cat /sys/module/$MODULE_NAME/parameters/runtime_pm 2>/dev/null)" = Y ]; then
                        sleep "$IDLE_WAIT"
                        if cg_capture_ok; then
                            result INFO "crop-geometry.$label.recovered" \
                                "a runtime-PM cycle reloaded firmware for the next rectangle"
                            return
                        fi
                    fi
                    result WARN "crop-geometry.$label.recovered" \
                        "the channel did not come back; later rectangles are not trustworthy"
                fi
            }

            # -- phase 1: 640-wide crop walked across the array to its edge
            cg_set_output "$CROP_WIDTH" "$CROP_HEIGHT"
            cg_centre=$(( (cg_sensor_w - cg_out_w) / 2 ))
            cg_far_left=$(( cg_sensor_w - cg_out_w ))
            result INFO crop-geometry.phase1 \
                "${cg_out_w}x${cg_out_h} crop on ${cg_sensor_w}x${cg_sensor_h}; far edge at left $cg_far_left"

            cg_probe 0 0 "$cg_sensor_w" "$cg_sensor_h" full
            cg_probe "$cg_centre" 0 "$cg_out_w" "$cg_out_h" "centre$cg_centre"
            for cg_step in 8 80; do
                cg_probe $(( cg_centre + cg_step )) 0 "$cg_out_w" "$cg_out_h" \
                         "right$(( cg_centre + cg_step ))"
            done
            cg_probe "$cg_far_left" 0 "$cg_out_w" "$cg_out_h" edge
            cg_probe $(( cg_far_left + 64 )) 0 "$cg_out_w" "$cg_out_h" pastedge clamped

            # -- phase 2: narrower crop, so the edge sits further right
            cg_set_output $(( CROP_WIDTH / 2 )) $(( CROP_HEIGHT / 2 ))
            if [ "$cg_out_w" -ge "$CROP_WIDTH" ]; then
                result SKIP crop-geometry.phase2 \
                    "the driver would not accept a narrower output; cannot vary crop width"
            else
                cg_far_left2=$(( cg_sensor_w - cg_out_w ))
                result INFO crop-geometry.phase2 \
                    "${cg_out_w}x${cg_out_h} crop; far edge at left $cg_far_left2"
                cg_probe "$cg_far_left2" 0 "$cg_out_w" "$cg_out_h" narrow_edge
                cg_probe $(( cg_far_left2 + 80 )) 0 "$cg_out_w" "$cg_out_h" \
                         narrow_pastedge clamped
            fi

            # -- phase 3: the vertical axis, which is not rounded, so a
            # one-pixel step past the edge is expressible.
            cg_set_output "$CROP_WIDTH" "$CROP_HEIGHT"
            cg_far_top=$(( cg_sensor_h - cg_out_h ))
            result INFO crop-geometry.phase3 \
                "vertical axis at left 0: ${cg_out_w}x${cg_out_h} crop, far edge at top $cg_far_top"
            cg_probe 0 $(( cg_far_top / 2 + 1 )) "$cg_out_w" "$cg_out_h" "vmid$(( cg_far_top / 2 + 1 ))"
            cg_probe 0 "$cg_far_top" "$cg_out_w" "$cg_out_h" vedge
            cg_probe 0 $(( cg_far_top + 1 )) "$cg_out_w" "$cg_out_h" vpastedge clamped

            if [ -n "$cg_default" ]; then
                IFS=, read -r cd_l cd_t cd_w cd_h <<<"$cg_default"
                v4l2-ctl --device "$DEVICE" \
                    --set-selection="target=crop,left=$cd_l,top=$cd_t,width=$cd_w,height=$cd_h" \
                    >>"$REPORT" 2>&1 || true
            fi
            if [ -n "$cg_orig_wh" ]; then
                v4l2-ctl --device "$DEVICE" \
                    --set-fmt-video="width=${cg_orig_wh%%/*},height=${cg_orig_wh##*/},pixelformat=YUYV" \
                    >>"$REPORT" 2>&1 || true
            fi
        fi
    fi
fi

# ============================================================================
# Section: nv12
# DOWNSTREAM.md - "Pixel formats"
#
# The ISP's semi-planar output, format code 0, is NV12. That is a hardware
# result, not a reading of the code: a capture wrote a width*height luma plane
# followed by exactly width*height/2 of chroma and left the rest of an
# NV16-sized buffer at zero, with Cb/Cr matching a YUYV capture of the same
# scene. Every earlier reading of this driver, upstream's included, assumed
# 4:2:2 and called it NV16.
#
# It is a normally advertised format now, so this runs by default and needs no
# module reload. It stays a standing regression check because each of its
# assertions exists for a failure that already happened once:
#
#   - G_FMT is re-read because an early NV16 "pass" was really YUYV; the fourcc
#     was silently coerced and both formats had the same byte count.
#   - The luma rows are checked for a blank-row pattern because a row stride the
#     ISP disagrees with makes it skip rows rather than overrun anything - no
#     fault, and a frame that is half empty.
#   - The planes are measured at their 4:2:0 extents, because reading chroma
#     over a 4:2:2 extent averages it with unwritten zeros and reports a wrong
#     number that looks like a wrong format.
#   - Chroma is compared against a YUYV capture of the same scene rather than an
#     absolute threshold, which is what turned "the chroma looks wrong" into
#     "the chroma is 4:2:0".
# ============================================================================
if wants nv12; then
    step "nv12: semi-planar 4:2:0 capture"
    log_section "SECTION nv12"

    [ -n "$DEVICE" ] || wait_for_device || true
    if [ -z "$DEVICE" ]; then
        result SKIP nv12 "no video node"
    else
        if v4l2-ctl --device "$DEVICE" --list-formats 2>/dev/null | grep -q NV12; then
            result PASS nv12.enum "ENUM_FMT advertises NV12"
        else
            result FAIL nv12.enum "ENUM_FMT does not advertise NV12"
        fi

        # Index 0 is what an application that takes the first format offered
        # ends up with, and NV12 is meant to be that format now.
        #
        # --list-formats has two layouts and both must be read, because a
        # layout this cannot parse yields an empty string that reads as a
        # driver enumerating the wrong format. v4l2-utils <= 1.22 prints a
        # labelled block ("Pixel Format: 'NV12'"); 1.32 prints
        # "[0]: 'NV12' (Y/UV 4:2:0)". The labelled form is still what
        # --get-fmt-video prints, which is why fmt_field() needs no such pair.
        # Both are enumeration-ordered, so head -1 is index 0 either way.
        nv12_first="$(v4l2-ctl --device "$DEVICE" --list-formats 2>/dev/null |
            sed -n \
                -e "s/^[[:space:]]*\[[0-9]\{1,\}\][[:space:]]*:[[:space:]]*'\([^']*\)'.*/\1/p" \
                -e "s/^[[:space:]]*Pixel Format[[:space:]]*:[[:space:]]*'\([^']*\)'.*/\1/p" |
            head -1)"
        if [ "$nv12_first" = NV12 ]; then
            result PASS nv12.first "NV12 is the first format enumerated"
        else
            result FAIL nv12.first \
                "ENUM_FMT index 0 is '${nv12_first:-unknown}', not NV12"
        fi

        dmesg_mark
        v4l2-ctl --device "$DEVICE" --set-fmt-video=pixelformat=NV12 \
            >>"$REPORT" 2>&1 || true
        nv12_fmt="$(fmt_field 'Pixel Format')"
        case "$nv12_fmt" in
            *NV12*)
                result PASS nv12.gfmt "G_FMT still reports NV12 after S_FMT" ;;
            *)
                result FAIL nv12.gfmt \
                    "S_FMT was coerced away from NV12 to '$nv12_fmt' - the old false pass" ;;
        esac

        nv12_wh="$(fmt_field 'Width\/Height')"
        nv12_w="${nv12_wh%%/*}"
        nv12_h="${nv12_wh##*/}"
        nv12_bpl="$(fmt_field 'Bytes per Line')"
        nv12_size="$(fmt_field 'Size Image')"
        log "NV12 format: ${nv12_w}x${nv12_h} bpl=$nv12_bpl sizeimage=$nv12_size"

        if [ "$nv12_bpl" = "$nv12_w" ]; then
            result PASS nv12.stride \
                "bytesperline is $nv12_bpl, the luma plane's own stride"
        else
            result FAIL nv12.stride \
                "bytesperline is $nv12_bpl, expected $nv12_w for a one-byte luma plane"
        fi
        if [ "$nv12_size" = "$(( nv12_w * nv12_h * 3 / 2 ))" ]; then
            result PASS nv12.sizeimage \
                "sizeimage is $nv12_size, luma plus a half-height chroma plane"
        else
            result FAIL nv12.sizeimage \
                "sizeimage is $nv12_size, expected $(( nv12_w * nv12_h * 3 / 2 )) for 4:2:0"
        fi

        nv12_file=/tmp/facetimehd-nv12.raw
        rm -f "$nv12_file"
        if capture_ok "$NV12_FRAMES" >/dev/null 2>&1 &&
           v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count="$NV12_FRAMES" \
                --stream-to="$nv12_file" >>"$REPORT" 2>&1; then
            result PASS nv12.capture "captured $NV12_FRAMES NV12 frames"
        else
            result FAIL nv12.capture "NV12 capture failed"
        fi

        nv12_bytes="$(stat -c %s "$nv12_file" 2>/dev/null || echo 0)"
        nv12_frames_got=$(( nv12_size > 0 ? nv12_bytes / nv12_size : 0 ))
        if [ "$nv12_size" -gt 0 ] &&
           [ "$(( nv12_bytes % nv12_size ))" -eq 0 ] &&
           [ "$nv12_frames_got" -gt 0 ]; then
            result PASS nv12.frames \
                "$nv12_bytes bytes is exactly $nv12_frames_got frames of $nv12_size"
        else
            result FAIL nv12.frames \
                "$nv12_bytes bytes is not a whole number of $nv12_size-byte frames"
        fi

        if [ "$nv12_frames_got" -gt 0 ]; then
            luma_len=$(( nv12_w * nv12_h ))
            chroma_len=$(( luma_len / 2 ))
            frame_off=$(( (nv12_frames_got - 1) * nv12_size ))
            luma="$(plane_stats "$nv12_file" "$frame_off" "$luma_len" || true)"
            chroma="$(plane_stats "$nv12_file" "$(( frame_off + luma_len ))" \
                      "$chroma_len" || true)"
            log "luma plane:   ${luma:-unreadable}"
            log "chroma plane: ${chroma:-unreadable}"

            if [ -z "$luma" ] || [ -z "$chroma" ]; then
                result FAIL nv12.planes "could not sample both planes"
            else
                luma_mean="${luma%% *}"
                chroma_mean="${chroma%% *}"
                chroma_min="$(printf '%s\n' "$chroma" | awk '{print $2}')"
                chroma_max="$(printf '%s\n' "$chroma" | awk '{print $3}')"

                if awk -v m="$luma_mean" 'BEGIN{exit !(m >= 8 && m <= 247)}'; then
                    result PASS nv12.luma \
                        "luma plane mean $luma_mean is a real exposure, not a floor or a ceiling"
                else
                    result WARN nv12.luma \
                        "luma plane mean $luma_mean is at a floor or ceiling - relight the scene and re-run"
                fi

                if [ "$chroma_min" = "$chroma_max" ]; then
                    result FAIL nv12.chroma \
                        "chroma plane is a constant $chroma_min - the ISP never wrote it, so addr1 is not where it puts chroma"
                elif awk -v m="$chroma_mean" 'BEGIN{exit !(m >= 100 && m <= 156)}'; then
                    result PASS nv12.chroma \
                        "chroma plane mean $chroma_mean sits around the 128 neutral point, as interleaved CbCr should"
                else
                    result FAIL nv12.chroma \
                        "chroma plane mean $chroma_mean is nowhere near the 128 neutral point - compare nv12.chroma_ref below before believing the scene is at fault"
                fi
            fi

            # Row-stride check on the luma plane.
            zero_rows="$(plane_zero_rows "$nv12_file" "$frame_off" "$nv12_w" 60 || true)"
            if [ -z "$zero_rows" ]; then
                result WARN nv12.stride_rows "could not sample luma rows"
            elif awk -v z="$zero_rows" 'BEGIN{exit !(z < 2)}'; then
                result PASS nv12.stride_rows \
                    "no blank luma rows ($zero_rows% of the sampled rows are all zero)"
            else
                result FAIL nv12.stride_rows \
                    "$zero_rows% of sampled luma rows are entirely zero - the ISP is writing at a different row stride than the buffer is laid out for"
            fi

        else
            result SKIP nv12.planes "no complete frame to examine"
        fi

        # The chroma verdict is only meaningful against a reference from the
        # same sensor and scene, in a format already known good.
        v4l2-ctl --device "$DEVICE" --set-fmt-video=pixelformat=YUYV \
            >>"$REPORT" 2>&1 || true
        ref_file=/tmp/facetimehd-nv12-yuyv-reference.raw
        ref_size="$(fmt_field 'Size Image')"
        rm -f "$ref_file"
        if capture_ok 5 >/dev/null 2>&1 &&
           v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=5 \
                --stream-to="$ref_file" >>"$REPORT" 2>&1 &&
           ref="$(yuyv_chroma_means "$ref_file" "$ref_size")"; then
            log "YUYV reference chroma (Cb Cr): $ref"
            result INFO nv12.chroma_ref \
                "same scene in YUYV gives Cb/Cr $ref against NV12's chroma mean ${chroma_mean:-unknown}"
        else
            result WARN nv12.chroma_ref \
                "could not capture a YUYV reference for the chroma comparison"
        fi

        dmesg_driver >>"$REPORT"
        if faults_present; then
            result FAIL nv12.faults \
                "firmware, buffer, IOMMU or DMAR fault during NV12 capture"
        else
            result PASS nv12.faults \
                "no firmware, buffer, IOMMU or DMAR faults during NV12 capture"
        fi
        # Leave the node on a packed format. Nothing depends on it any more -
        # every section that parses pixels asks for one itself - but leaving a
        # run's device on the format its parsers want costs nothing.
        use_packed_format || true
    fi
fi

# ============================================================================
# Section: reboot (opt-in, two-phase)
# DOWNSTREAM.md - "Validation", reboot/kexec while streaming
#
# fthd_pci_shutdown() runs at reboot instead of fthd_pci_remove(). It cannot
# be tested without actually rebooting, so this arms a marker, starts a
# stream and reboots; the next run reads the marker and checks the log.
# ============================================================================
if [ -f "$REBOOT_STATE" ]; then
    step "reboot: reading the verdict from the previous run"
    log_section "SECTION reboot (post-reboot check)"
    armed_at="$(cat "$REBOOT_STATE" 2>/dev/null || echo unknown)"
    rm -f "$REBOOT_STATE"

    # A clean shutdown path leaves no oops/warning in the previous boot's log.
    if have journalctl; then
        prev="$(journalctl -b -1 -k --no-pager 2>/dev/null || true)"
        if [ -z "$prev" ]; then
            result INFO reboot.prev "no previous boot in the journal to inspect"
        elif printf '%s' "$prev" | grep -qiE "call trace|kernel bug|oops|warn_on.*fthd|$MODULE_NAME.*warn"; then
            result FAIL reboot.clean \
                "previous boot logged a trace/oops around shutdown - see report"
            printf '%s\n' "$prev" | grep -iE -A20 "call trace|oops|$MODULE_NAME" >>"$REPORT"
        else
            result PASS reboot.clean \
                "machine rebooted while streaming (armed $armed_at) with a clean log"
        fi
    else
        result INFO reboot.clean \
            "rebooted while streaming (armed $armed_at); no journalctl to check the previous boot"
    fi
fi

if [ "$DO_REBOOT" = 1 ]; then
    step "reboot: arming the shutdown-path test"
    [ -n "$DEVICE" ] || wait_for_device || die "no video node to stream from"
    mkdir -p "$STATE_DIR"
    date -Is >"$REBOOT_STATE"
    warn "Starting a stream and rebooting. Re-run this script afterwards to"
    warn "read the verdict. Ctrl-C now to abort."
    if [ "$INTERACTIVE" = 1 ]; then
        confirm "Reboot now with the camera streaming?" || {
            rm -f "$REBOOT_STATE"; die "aborted"
        }
    fi
    v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count=100000 \
             --stream-to=/dev/null >/dev/null 2>&1 &
    sleep 3
    sync
    systemctl reboot || reboot
    exit 0
fi

# ---------------------------------------------------------------- summary ----

log_section "SUMMARY"
printf '\n'
step "Summary"
for r in "${RESULTS[@]}"; do
    status="${r%%|*}"; rest="${r#*|}"
    id="${rest%%|*}"; msg="${rest#*|}"
    printf '  %-5s %-26s %s\n' "$status" "$id" "$msg"
    log "$(printf '%-5s %-26s %s' "$status" "$id" "$msg")"
done

printf '\n'
if [ "$FAILED" -eq 0 ]; then
    ok "No failures. Report: $REPORT"
    info "Items marked INFO/WARN still need a human to read them - especially"
    info "the timing profile and any luma numbers."
else
    error "Failures above. Report: $REPORT"
    error "Attach that file when reporting; it has the driver's dmesg output."
fi

if [ "$DMESG_WRAPPED" -eq 1 ]; then
    warn "The kernel ring buffer wrapped during this run, so some evidence was"
    warn "evicted before it could be read. This driver logs its whole DDR/PLL"
    warn "bring-up at dev_info on every runtime-PM resume, which is enough to"
    warn "fill the default buffer in a couple of minutes. Re-run with a bigger"
    warn "buffer for a trustworthy result:  log_buf_len=4M on the kernel cmdline"
fi

if ! wants suspend; then
    info "Not covered by this run: suspend-while-streaming."
fi
[ "$DO_REBOOT" = 1 ] || info "Not covered by this run: reboot while streaming (--reboot)."

exit "$FAILED"
