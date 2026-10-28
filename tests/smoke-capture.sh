#!/usr/bin/env bash
#
# Exercise the installed driver on real hardware.
#
# CI cannot run this: it needs a 2013-2015 MacBook with the camera present, the
# firmware installed and the module loadable. That is exactly why it exists -
# ./tests/build-driver.sh only proves the driver compiles, and every V4L2 bug
# this project has fixed was invisible to a compiler.
#
#   sudo ./tests/smoke-capture.sh              # load, capture, check, leave loaded
#   sudo ./tests/smoke-capture.sh --unload     # remove the module afterwards
#   ./tests/smoke-capture.sh --no-load         # module already loaded, no root
#
# Needs v4l-utils. v4l2-compliance is the part that matters; the capture is
# there because a driver can pass compliance and still never deliver a frame.
# It is packaged separately on Fedora (v4l-utils-devel-tools) and not at all on
# Enterprise Linux 10, whose v4l-utils leaves it out - so its absence skips that
# one section, loudly, rather than refusing to test anything.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"

MODULE_NAME=facetimehd
FRAMES="${FRAMES:-30}"
DEVICE="${DEVICE:-}"
DO_LOAD=1
KEEP=1

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

      --no-load   Do not modprobe/rmmod; test whatever is already loaded.
      --unload    Remove the module when finished. Off by default: leaving the
                  machine with no camera is a worse failure than leaving a
                  module loaded, and nothing reloads it until the next boot.
  -h, --help      Show this help.

Environment:
  DEVICE   Video node to test (default: the first node claimed by $MODULE_NAME).
  FRAMES   Frames to capture (default: 30).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-load) DO_LOAD=0 ;;
        --unload)  KEEP=0 ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; die "Unknown argument: $1" ;;
    esac
    shift
done

require_cmds v4l2-ctl
HAVE_COMPLIANCE=1
have v4l2-compliance || HAVE_COMPLIANCE=0
[ "$DO_LOAD" -eq 0 ] || require_root

has_facetimehd_hardware ||
    die "No FaceTime HD camera (14e4:1570) on this machine - nothing to test."

# Find the node this driver owns rather than assuming /dev/video0: an external
# webcam or a v4l2loopback can easily hold the lower number.
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

# Invoked only via `trap cleanup EXIT` below. shellcheck's reachability check
# for trap-registered functions gets confused by the explicit `exit "$rc"`
# this script ends on - it reports the function as unreachable (SC2329 on
# 0.9+, SC2317 on older releases) even though the trap fires on that exit same
# as any other. Silence both codes rather than pin a shellcheck version.
# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ "$DO_LOAD" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
        modprobe -r "$MODULE_NAME" 2>/dev/null || true
        warn "$MODULE_NAME unloaded (--unload). There is no /dev/videoN until"
        warn "you run: sudo modprobe $MODULE_NAME"
    fi
}
trap cleanup EXIT

if [ "$DO_LOAD" -eq 1 ]; then
    step "Loading $MODULE_NAME"
    modprobe -r "$MODULE_NAME" 2>/dev/null || true
    modprobe "$MODULE_NAME" || die "modprobe $MODULE_NAME failed - see dmesg."
    # The V4L2 node appears a moment after probe() returns.
    for _ in $(seq 1 20); do
        DEVICE="$(find_device || true)"
        [ -n "$DEVICE" ] && break
        sleep 0.5
    done
fi

[ -n "$DEVICE" ] || DEVICE="$(find_device || true)"
[ -n "$DEVICE" ] || die "No video node claimed by $MODULE_NAME - see dmesg."
ok "Testing $DEVICE"

rc=0

step "Device capabilities"
v4l2-ctl --device "$DEVICE" --info

step "Formats, sizes and intervals"
v4l2-ctl --device "$DEVICE" --list-formats-ext

step "Controls"
v4l2-ctl --device "$DEVICE" --list-ctrls

# A control set while the channel is down must be remembered and applied at
# STREAMON, not silently dropped - that is the bug the control replay fixed.
step "Control round-trip while not streaming"
if v4l2-ctl --device "$DEVICE" --set-ctrl brightness=100 >/dev/null 2>&1; then
    got="$(v4l2-ctl --device "$DEVICE" --get-ctrl brightness 2>/dev/null |
           sed -n 's/^brightness: //p')"
    if [ "$got" = 100 ]; then
        ok "brightness reads back as set"
    else
        bad "brightness read back as '${got:-<nothing>}', expected 100"
        rc=1
    fi
    v4l2-ctl --device "$DEVICE" --set-ctrl brightness=128 >/dev/null 2>&1 || true
else
    bad "could not set brightness while stopped"
    rc=1
fi

step "Capturing $FRAMES frames"
if v4l2-ctl --device "$DEVICE" --stream-mmap --stream-count="$FRAMES" \
            --stream-to=/dev/null; then
    ok "captured $FRAMES frames"
else
    bad "capture failed"
    rc=1
fi

# -s streams as part of the test; it is the only mode that exercises the queue
# and format negotiation together.
step "v4l2-compliance"
if [ "$HAVE_COMPLIANCE" -eq 0 ]; then
    warn "v4l2-compliance is not installed, so this section was NOT run."
    if is_debian_like; then
        warn "Install it with: sudo apt install v4l-utils"
    elif is_enterprise_linux; then
        warn "Enterprise Linux does not package it; build v4l-utils from"
        warn "https://git.linuxtv.org/v4l-utils.git, or run this on Fedora/Ubuntu."
    else
        warn "Install it with: sudo dnf install v4l-utils-devel-tools"
    fi
elif v4l2-compliance --device "$DEVICE" -s; then
    ok "v4l2-compliance passed"
else
    bad "v4l2-compliance reported failures"
    rc=1
fi

if [ "$rc" -eq 0 ] && [ "$HAVE_COMPLIANCE" -eq 0 ]; then
    ok "All checks that ran passed - v4l2-compliance was skipped"
elif [ "$rc" -eq 0 ]; then
    ok "All checks passed"
else
    error "Some checks failed - see above, and check dmesg for driver messages."
fi
exit "$rc"
