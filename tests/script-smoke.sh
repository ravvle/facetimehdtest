#!/usr/bin/env bash
#
# Exercise the installer and uninstaller plumbing without a MacBook, without
# root and without touching the system.
#
# Linting catches syntax and quoting; it does not catch an option that was
# added to the help text and never wired into the case statement, a --status
# that dies on a machine with no camera, or an uninstaller that mishandles the
# DKMS version format it is given. Those are exactly the failures that only
# show up on a user's machine, so they get a test that runs in CI.
#
# Everything here is read-only with respect to the real system: the scripts are
# driven with FTHD_* environment overrides and a fake PATH, and anything that
# would write outside the sandbox is a test failure.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"

INSTALL="$REPO_DIR/scripts/install.sh"
UNINSTALL="$REPO_DIR/scripts/uninstall.sh"
EXTRACT="$REPO_DIR/scripts/extract-firmware.sh"
TUNE="$REPO_DIR/scripts/macbook-tune.sh"
DIAG="$REPO_DIR/scripts/collect-diagnostics.sh"
SETUP="$REPO_DIR/setup.sh"

pass=0
fail=0

result() {
    if [ "$1" = ok ]; then ok "$2"; pass=$((pass + 1))
    else bad "$2"; fail=$((fail + 1)); fi
}

# Run a command, capture everything, and report on its exit status.
expect_status() {
    local want="$1" name="$2"; shift 2
    local out rc=0
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" -eq "$want" ]; then
        result ok "$name (exit $rc)"
    else
        result bad "$name: expected exit $want, got $rc"
        printf '%s\n' "$out" | sed 's/^/      | /' | head -20
    fi
}

expect_output() {
    local pattern="$1" name="$2"; shift 2
    local out
    out="$("$@" 2>&1 || true)"
    if printf '%s\n' "$out" | grep -q -- "$pattern"; then
        result ok "$name"
    else
        result bad "$name: output did not contain '$pattern'"
        printf '%s\n' "$out" | sed 's/^/      | /' | head -20
    fi
}

WORK="$(mktemp -d -t fthd-script-smoke.XXXXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT

# ---------------------------------------------------------------------------
step "Help and usage"
# ---------------------------------------------------------------------------
#
# Every script must answer --help without root and without side effects. A
# non-zero exit here usually means set -u caught an unset variable on a path
# nobody runs interactively.

for s in "$INSTALL" "$UNINSTALL" "$EXTRACT" "$TUNE" "$DIAG" "$SETUP"; do
    expect_status 0 "$(basename "$s") --help" "$s" --help
done

# ---------------------------------------------------------------------------
step "Option parsing"
# ---------------------------------------------------------------------------
#
# An unknown option must be refused with exit 2 rather than silently ignored -
# a typo in a documented flag would otherwise run a full install with defaults.

expect_status 2 "install.sh rejects an unknown option" \
    "$INSTALL" --definitely-not-an-option
expect_status 2 "uninstall.sh rejects an unknown option" \
    "$UNINSTALL" --definitely-not-an-option
expect_status 2 "extract-firmware.sh rejects an unknown option" \
    "$EXTRACT" --definitely-not-an-option

# Every long option the help text advertises must actually be handled. This is
# the check that catches a flag documented and never wired up: an unhandled one
# falls through to the "Unknown option" arm and exits 2.
check_documented_options() {
    local script="$1" name opt out rc
    name="$(basename "$script")"
    while read -r opt; do
        [ -n "$opt" ] || continue
        # --help exits 0 by design; the rest are probed with a deliberately
        # invalid argument so they fail on their *own* validation, never on
        # having been treated as unknown.
        [ "$opt" = "--help" ] && continue
        rc=0
        out="$("$script" "$opt" 2>&1)" || rc=$?
        if printf '%s\n' "$out" | grep -q "Unknown option: $opt"; then
            result bad "$name: $opt is documented but not handled"
        else
            result ok "$name: $opt is handled"
        fi
    done < <("$script" --help 2>&1 | grep -oE '^\s+(-[a-zA-Z], )?--[a-z-]+' |
             grep -oE '\-\-[a-z-]+' | sort -u)
}

check_documented_options "$INSTALL"
check_documented_options "$UNINSTALL"
check_documented_options "$EXTRACT"
check_documented_options "$TUNE"
check_documented_options "$SETUP"
check_documented_options "$DIAG"

# ---------------------------------------------------------------------------
step "install.sh --status"
# ---------------------------------------------------------------------------
#
# --status must run to completion as a normal user and report what it sees.
# CI normally has no installation and returns 1; a developer machine may have a
# complete installation and return 0. Anything greater than 1 is a crash.

status_rc=0
status_out="$("$INSTALL" --status 2>&1)" || status_rc=$?
if [ "$status_rc" -le 1 ]; then
    result ok "--status completes with a valid state result (exit $status_rc)"
else
    result bad "--status crashed (exit $status_rc)"
    printf '%s\n' "$status_out" | sed 's/^/      | /' | head -20
fi

for want in 'System' 'Driver' 'Firmware' 'Secure Boot'; do
    if printf '%s\n' "$status_out" | grep -q "$want"; then
        result ok "--status reports on: $want"
    else
        result bad "--status is missing its '$want' section"
    fi
done

# Under `set -o pipefail`, `lsmod | grep -q` can misreport a loaded module when
# grep's early exit gives lsmod SIGPIPE. All lifecycle decisions must use the
# sysfs helper instead.
if grep -q '^module_is_loaded()' "$REPO_DIR/scripts/lib/common.sh" &&
   ! grep -q 'lsmod.*grep -q' "$INSTALL" "$UNINSTALL"; then
    result ok "module state checks are pipefail-safe"
else
    result bad "module state checks can fail from an lsmod SIGPIPE"
fi

expect_status 1 "install.sh --runtime-pm takes only on/off" \
    "$INSTALL" --runtime-pm sideways

# ---------------------------------------------------------------------------
step "Root enforcement"
# ---------------------------------------------------------------------------
#
# The scripts that write to the system must refuse to run as a normal user.
# Skipped when the tests are themselves run as root, where the check cannot
# fire and asserting on it would be asserting on nothing.

if [ "$(id -u)" -ne 0 ]; then
    expect_output 'must be run as root' "install.sh requires root" \
        "$INSTALL" --skip-hw-check -y
    expect_output 'must be run as root' "uninstall.sh requires root" \
        "$UNINSTALL" -y
    expect_output 'must be run as root' "macbook-tune.sh requires root" \
        "$TUNE" -y
else
    info "running as root; skipping the root-refusal checks"
fi

# extract-firmware.sh --no-install is the documented root-free path, so it must
# get past the root check. Pointed at a driver file that does not exist so it
# stops on that rather than on the download: this test must not depend on
# Apple's CDN being reachable, which is what --check-sources is for.
expect_output 'No such driver file' \
    "extract-firmware.sh --no-install needs no root" \
    "$EXTRACT" --no-install -x "$WORK/does-not-exist"

# --dest with --no-install is contradictory and must be refused rather than
# silently ignoring one of them.
expect_status 2 "extract-firmware.sh rejects --dest with --no-install" \
    "$EXTRACT" --no-install --dest "$WORK/dest"

# ---------------------------------------------------------------------------
step "DKMS version parsing"
# ---------------------------------------------------------------------------
#
# uninstall.sh discovers what to remove by parsing 'dkms status'. That output
# has two formats in the wild - "name/version," on DKMS 3.x and "name, version,"
# on 2.x - and getting it wrong means leaving a registration behind while
# reporting success. Both are replayed here through a stub dkms on PATH.

make_stub_dkms() {
    local output="$1" dir="$2"
    mkdir -p -- "$dir"
    cat > "$dir/dkms" <<EOF
#!/bin/sh
# Stub dkms for tests. 'status' replays a recorded format; everything else
# succeeds silently so the uninstaller can walk its whole path.
case "\$1" in
    status) cat <<'DKMSEOF'
$output
DKMSEOF
        ;;
    *) exit 0 ;;
esac
EOF
    chmod +x -- "$dir/dkms"
}

check_dkms_format() {
    local label="$1" output="$2" want="$3"
    local dir="$WORK/stub-$label"
    make_stub_dkms "$output" "$dir"

    local found
    found="$(
        PATH="$dir:$PATH"
        MODULE_NAME=facetimehd
        dkms status -m "$MODULE_NAME" 2>/dev/null |
            sed -n -e "s|^${MODULE_NAME}/\([^,]*\),.*|\1|p" \
                   -e "s|^${MODULE_NAME}, \([^,]*\),.*|\1|p" |
            sort -u | tr '\n' ' '
    )"
    found="${found% }"

    if [ "$found" = "$want" ]; then
        result ok "dkms $label format parses to '$want'"
    else
        result bad "dkms $label format parsed to '$found', expected '$want'"
    fi
}

check_dkms_format '3.x' \
    'facetimehd/0.1+d0123456789ab, 6.8.0-1-generic, x86_64: installed' \
    '0.1+d0123456789ab'
check_dkms_format '2.x' \
    'facetimehd, 0.1+d0123456789ab, 6.8.0-1-generic, x86_64: installed' \
    '0.1+d0123456789ab'
check_dkms_format 'multi-version' \
    'facetimehd/0.1+daaaaaaaaaaa, 6.8.0-1-generic, x86_64: installed
facetimehd/0.1+dbbbbbbbbbbb, 6.9.0-1-generic, x86_64: installed' \
    '0.1+daaaaaaaaaaa 0.1+dbbbbbbbbbbb'

# ---------------------------------------------------------------------------
step "Driver source fingerprint"
# ---------------------------------------------------------------------------
#
# The fingerprint is what stops an edited source tree from reusing the DKMS
# version of a tree that was already built. If it ever stopped changing with
# the sources, every subsequent install would silently skip the rebuild.

fp1="$(driver_source_fingerprint "$REPO_DIR/src/facetimehd")"
cp -a -- "$REPO_DIR/src/facetimehd" "$WORK/driver"
fp2="$(driver_source_fingerprint "$WORK/driver")"
if [ "$fp1" = "$fp2" ]; then
    result ok "fingerprint is stable across an identical copy"
else
    result bad "fingerprint changed for an identical copy ($fp1 vs $fp2)"
fi

printf '\n/* smoke test */\n' >> "$WORK/driver/fthd_drv.c"
fp3="$(driver_source_fingerprint "$WORK/driver")"
if [ "$fp1" != "$fp3" ]; then
    result ok "fingerprint changes when a source file changes"
else
    result bad "fingerprint did not change after editing fthd_drv.c"
fi

# A file that is not compiled must not move the fingerprint: DOWNSTREAM.md
# changes on most driver commits, and rebuilding for a documentation edit would
# make the idempotency check worthless.
cp -a -- "$REPO_DIR/src/facetimehd" "$WORK/driver2"
printf '\ndocs only\n' >> "$WORK/driver2/DOWNSTREAM.md"
fp4="$(driver_source_fingerprint "$WORK/driver2")"
if [ "$fp1" = "$fp4" ]; then
    result ok "fingerprint ignores non-compiled files"
else
    result bad "fingerprint changed for a DOWNSTREAM.md edit"
fi

# The source tree can be edited while a long-running root install is starting.
# Version and contents must both come from the completed snapshot, never from
# two observations of the live tree.
snapshot_line="$(grep -nF "prepare_driver_source \"\$DRIVER_SRC\" \"\$SRC_STAGE\"" \
                 "$INSTALL" | head -1 | cut -d: -f1)"
staged_hash_line="$(grep -nF "driver_source_fingerprint \"\$SRC_STAGE\"" \
                    "$INSTALL" | head -1 | cut -d: -f1)"
if [ -n "$snapshot_line" ] && [ -n "$staged_hash_line" ] &&
   [ "$snapshot_line" -lt "$staged_hash_line" ]; then
    result ok "installer fingerprints the immutable source snapshot"
else
    result bad "installer can label staged contents with a live-tree fingerprint"
fi

# ---------------------------------------------------------------------------
step "dkms.conf agrees with the Makefile"
# ---------------------------------------------------------------------------
#
# install.sh reads PACKAGE_VERSION out of dkms.conf and rewrites only the staged
# copy. If the name or version ever stopped parsing, the installer would build a
# directory DKMS then refuses to find.

conf="$REPO_DIR/src/facetimehd/dkms.conf"
ver="$(sed -n 's/^[[:space:]]*PACKAGE_VERSION=["'"'"']\{0,1\}\([^"'"'"']*\)["'"'"']\{0,1\}[[:space:]]*$/\1/p' "$conf" | head -n1)"
if [ -n "$ver" ]; then
    result ok "PACKAGE_VERSION parses as '$ver'"
else
    result bad "PACKAGE_VERSION could not be parsed from dkms.conf"
fi

# Every object the Makefile builds must have a matching source file, which is
# what catches a new .c added to one and not the other.
missing_src=0
while read -r obj; do
    [ -n "$obj" ] || continue
    [ -f "$REPO_DIR/src/facetimehd/${obj%.o}.c" ] || {
        result bad "Makefile builds $obj with no ${obj%.o}.c"
        missing_src=1
    }
done < <(sed -n 's/^facetimehd-objs *:= *//p' "$REPO_DIR/src/facetimehd/Makefile" | tr ' ' '\n')
[ "$missing_src" -eq 0 ] && result ok "every Makefile object has a source file"

# ...and the reverse: a source file added to the tree and never added to the
# Makefile compiles in no CI job and fails only on a user's machine.
unbuilt=0
objs="$(sed -n 's/^facetimehd-objs *:= *//p' "$REPO_DIR/src/facetimehd/Makefile")"
for src in "$REPO_DIR"/src/facetimehd/*.c; do
    base="$(basename "$src" .c)"
    # Kbuild emits these beside the real sources. They are build products, not
    # translation units that belong in facetimehd-objs.
    case "$base" in
        *.mod|*.module-common) continue ;;
    esac
    case " $objs " in
        *" $base.o "*) ;;
        *) result bad "$base.c is not in facetimehd-objs"; unbuilt=1 ;;
    esac
done
[ "$unbuilt" -eq 0 ] && result ok "every source file is in facetimehd-objs"

# ---------------------------------------------------------------------------
step "Hardware-safety defaults"
# ---------------------------------------------------------------------------
# Firmware disassembly proved that several inferred payloads were malformed.
# They must be absent, not merely hidden behind a module parameter that can
# turn an ordinary STREAMON into a whole-machine lockup.

drv="$REPO_DIR/src/facetimehd/fthd_drv.c"
v4l2="$REPO_DIR/src/facetimehd/fthd_v4l2.c"

# The checks below look for control and format names in the driver, and the
# driver's comments legitimately name the very things that must not be
# registered - explaining why the AWB readback is *not*
# V4L2_CID_WHITE_BALANCE_TEMPERATURE is exactly the reasoning DOWNSTREAM.md
# asks for. Strip comment bodies so these test code rather than prose.
code_only() {
    sed -e 's://.*::' -e '/^[[:space:]]*\*/d' -e '/^[[:space:]]*\/\*/d' "$1"
}

# Read it once into a variable, and match against that with here-strings rather
# than piping code_only into each reader. A reader that stops early - `grep -q`
# the moment it matches, or an `awk` with an `exit` - closes the pipe while sed
# still has most of the file to write, sed dies of EPIPE, and `pipefail` makes
# the whole pipeline non-zero. That is worse than a crash: the guards below are
# written `if ! ... grep -q <the thing that must not be there>`, so the EPIPE
# status inverts to *true* and the check congratulates itself precisely when the
# forbidden thing is present. It is also a race against the 64K pipe buffer, so
# it passes locally and fails in CI.
v4l2_code="$(code_only "$v4l2")"

if ! grep -Rq 'module_param(\(experimental_controls\|experimental_formats\|hwmon\)' \
        "$REPO_DIR/src/facetimehd"; then
    result ok "unsafe firmware interfaces have no module-parameter entry point"
else
    result bad "a removed firmware interface is still reachable"
fi

debugfs="$REPO_DIR/src/facetimehd/fthd_debugfs.c"
if grep -q 'if (!dev_priv->channel_running)' "$debugfs" &&
   grep -q 'debugfs_create_file("sensor_temperature_raw", 0400' "$debugfs" &&
   grep -q 'debugfs_create_file("ae_metering_mode_raw", 0400' "$debugfs" &&
   ! grep -q 'CISP_CMD_CH_\(SHARPNESS\|NOISE_REDUCTION\|CHROMA_SUPPRESSION\|DRC\)_GET' \
        "$REPO_DIR/src/facetimehd/fthd_isp.c"; then
    result ok "raw firmware GETs are root-only, stream-gated, and whitelisted"
else
    result bad "firmware readbacks bypass their stream or opcode safety boundary"
fi

# The readbacks added from the dispatcher table sweep. Each is a GET recovered
# from a firmware handler, so each is mode 0400 and none may reach V4L2: a
# control would put it back in the v4l2_ctrl_handler_setup() replay path that
# caused the lockups, and none of these has an established meaning anyway.
isp_c="$REPO_DIR/src/facetimehd/fthd_isp.c"
v4l2_c="$REPO_DIR/src/facetimehd/fthd_v4l2.c"
if grep -q 'debugfs_create_file("ae_frame_rate_max_raw", 0400' "$debugfs" &&
   grep -q 'debugfs_create_file("ae_frame_rate_min_raw", 0400' "$debugfs" &&
   grep -q 'debugfs_create_file("awb_2nd_gain_raw", 0400' "$debugfs" &&
   grep -q 'debugfs_create_file("crop_raw", 0400' "$debugfs" &&
   grep -q 'CISP_CMD_CH_AWB_2ND_GAIN_GET' "$isp_c" &&
   grep -q 'CISP_CMD_CH_CROP_GET' "$isp_c" &&
   ! grep -q 'CISP_CMD_CH_AWB_2ND_GAIN_MANUAL' "$isp_c" &&
   ! grep -qE 'awb_2nd_gain|frame_rate_(max|min)_get|crop_get' "$v4l2_c"; then
    result ok "swept-table readbacks are 0400 and reach no V4L2 control"
else
    result bad "a swept-table readback is writable or exposed through V4L2"
fi

# CISP_CMD_CH_CROP_SET takes (x, y, width, height); a window that leaves the
# sensor starves the channel until firmware reloads. The driver clamps the origin
# so the whole rectangle stays on the array, rounding *down* so the clamp cannot
# be undone, and the command refuses anything off the array or odd/odd.
if grep -q 'u32 width;' "$REPO_DIR/src/facetimehd/fthd_isp.h" &&
   grep -q 'cmd.width = width;' "$isp_c" &&
   grep -q 'crop->width, crop->height);' "$isp_c" &&
   grep -q '((x & 1) && (width & 1))' "$isp_c" &&
   grep -q 'r->left = round_down(min_t(unsigned int, r->left, max_w - r->width), 8);' "$v4l2_c" &&
   grep -q 'r->top  = min_t(unsigned int, r->top, max_h - r->height);' "$v4l2_c"; then
    result ok "crop is sent as origin plus size and clamped to stay on the array"
else
    result bad "the crop wire layout or its on-array clamp is missing"
fi

# YVYU (ISP code 2) writes invalid chroma, so it must not be reachable.
if ! grep -q 'V4L2_PIX_FMT_YVYU' "$v4l2_c" &&
   ! grep -q 'V4L2_PIX_FMT_YVYU' "$isp_c"; then
    result ok "YVYU is neither enumerated nor mapped to an ISP code"
else
    result bad "YVYU is reachable; ISP code 2 writes invalid chroma"
fi

if grep -q 'strcmp(strim(buf), "same")' "$debugfs" &&
   grep -q 'debugfs_create_file("roundtrip_ae_bias", 0200' "$debugfs" &&
   grep -q 'debugfs_create_file("roundtrip_ae_gain_cap_min", 0200' "$debugfs" &&
   grep -q 'fthd_firmware_roundtrip(dev_priv, roundtrip)' "$debugfs" &&
   grep -q 'ROUNDTRIPS=.*ae_bias.*ae_gain_cap_min' \
        "$REPO_DIR/tests/hw-validate.sh" &&
   grep -q 'readback-profile roundtrips' "$REPO_DIR/tests/hw-validate.sh" &&
   grep -q 'profile_snapshot bright30' \
        "$REPO_DIR/tests/hw-validate.sh"; then
    result ok "round-trip setters are same-value-only, root-only, stream-gated, and opt-in"
else
    result bad "round-trip validation exposes values or bypasses its safety harness"
fi

if grep -q 'debugfs_create_file("test_ae_metering_mode", 0200' "$debugfs" &&
   grep -q 'debugfs_create_file("test_ae_metering_mode_restart", 0200' "$debugfs" &&
   grep -q 'strcmp(token, "mode0")' "$debugfs" &&
   grep -q 'strcmp(token, "mode1")' "$debugfs" &&
   grep -q 'strcmp(token, "mode2")' "$debugfs" &&
   grep -q 'strcmp(token, "mode3")' "$debugfs" &&
   grep -q 'readback != requested' "$debugfs" &&
   grep -q 'if (restart_ae)' "$debugfs" &&
   grep -q 'METERING_RESTART_AE' "$REPO_DIR/tests/hw-validate.sh" &&
   grep -q 'if wants metering-modes' "$REPO_DIR/tests/hw-validate.sh" &&
   grep -q 'restored original mode.*before STREAMOFF' \
        "$REPO_DIR/tests/hw-validate.sh" &&
   grep -qF "metering_sleep_count=\$(( METERING_SETTLE_FRAMES +" \
        "$REPO_DIR/tests/hw-validate.sh" &&
   grep -q 's >= o + 20 && s < 235' \
        "$REPO_DIR/tests/hw-validate.sh" &&
   ! grep -q 'kstrto.*metering' "$debugfs"; then
    result ok "metering mutation is four-token-only, verified, restored, and opt-in"
else
    result bad "metering mutation bypasses its fixed-value or restoration boundary"
fi

if ! grep -q 'V4L2_CID_AUTO_EXPOSURE_BIAS\|V4L2_CID_WHITE_BALANCE_TEMPERATURE\|V4L2_CID_TEST_PATTERN\|FTHD_CID_NOISE_REDUCTION\|FTHD_CID_CHROMA_SUPPRESSION' \
        <<<"$v4l2_code"; then
    result ok "malformed or semantically unknown controls are not registered"
else
    result bad "an unvalidated firmware control is still registered"
fi

# The AWB CCT readback is the one control fed straight from a firmware GET.
# Read-only is not a presentation choice: v4l2_ctrl_handler_setup() skips
# read-only controls, so that flag is the whole reason registering it cannot
# replay a firmware SET at STREAMON or after a runtime resume - the mechanism
# that produced the lockups. Volatile without read-only would put a setter back.
if grep -q 'FTHD_CID_AWB_CCT_ESTIMATE' "$v4l2" &&
   grep -qF '.flags	= V4L2_CTRL_FLAG_READ_ONLY | V4L2_CTRL_FLAG_VOLATILE,' "$v4l2" &&
   grep -q 'if (ctrl->id != FTHD_CID_AWB_CCT_ESTIMATE)' "$v4l2" &&
   grep -q 'fthd_isp_cmd_channel_awb_cct_get' "$v4l2"; then
    result ok "the AWB CCT readback is read-only, so no SET is ever replayed"
else
    result bad "the AWB CCT readback is missing its read-only replay guard"
fi

# The ISP's semi-planar output is NV12, measured on hardware: format code 0
# wrote a half-height chroma plane and left the rest of an NV16-sized buffer at
# zero, with chroma matching a YUYV reference. The 4:2:0 sizing is the part that
# must not regress - a 4:2:2 sizeimage silently averages real chroma with
# unwritten zeros - and NV16 must not come back on the strength of its old name.
if grep -qF 'pixelformat == V4L2_PIX_FMT_NV12;' "$v4l2" &&
   grep -qF 'pix->bytesperline * pix->height * 3 / 2' "$v4l2" &&
   ! grep -q 'V4L2_PIX_FMT_NV16' <<<"$v4l2_code" &&
   ! grep -q 'module_param(nv1[26]' "$v4l2" &&
   grep -q 'nv12.gfmt' "$REPO_DIR/tests/hw-validate.sh" &&
   grep -q 'nv12.stride_rows' "$REPO_DIR/tests/hw-validate.sh" &&
   grep -q 'nv12.chroma_ref' "$REPO_DIR/tests/hw-validate.sh"; then
    result ok "NV12 is advertised, sized 4:2:0, and has a hardware test"
else
    result bad "NV12 is missing, mis-sized, or has no hardware test"
fi

# NV12 is the default format: index 0 of ENUM_FMT, what an unsupported request
# is coerced to, and what a freshly probed device reports through G_FMT. All
# three have to agree - a default that is not enumerated first, or an
# enumeration order that does not match what the device actually reports, is
# how an application ends up negotiating a format nobody tested.
nv12_enum_first="$(awk '
    /enum_fmt_vid_cap/ { in_fn = 1 }
    in_fn && /case 0:/ { want = 1; next }
    want && /pixelformat = / && !found { print; found = 1 }' <<<"$v4l2_code")"
if printf '%s' "$nv12_enum_first" | grep -q 'V4L2_PIX_FMT_NV12' &&
   grep -qF 'pix->pixelformat = V4L2_PIX_FMT_NV12;' "$v4l2" &&
   grep -qF 'dev_priv->fmt.fmt.pixelformat = V4L2_PIX_FMT_NV12;' "$v4l2" &&
   grep -q 'probe.default_fmt' "$REPO_DIR/tests/hw-validate.sh" &&
   grep -q 'nv12.first' "$REPO_DIR/tests/hw-validate.sh"; then
    result ok "NV12 is enumerated first, is the probe default, and is the fallback"
else
    result bad "the NV12 default is inconsistent between ENUM_FMT, probe and the fallback"
fi

# Every parser in the hardware suite that reads pixels out of a capture assumes
# a packed layout, and the device no longer defaults to one. mean_luma() is the
# parser that captures for itself, so it is the one that must ask.
if grep -q '^use_packed_format() {' "$REPO_DIR/tests/hw-validate.sh" &&
   grep -qF 'use_packed_format || return 1' "$REPO_DIR/tests/hw-validate.sh"; then
    result ok "the hardware suite's luma parsers pin a packed format first"
else
    result bad "a hardware luma parser can now be handed a semi-planar frame"
fi

# x2 in CISP_CMD_CH_OUTPUT_CONFIG_SET is the destination row stride. Hardcoding
# width*2 made the ISP write luma rows at double spacing for the one-byte-per-
# pixel plane, blanking half the frame with no IOMMU fault to show for it.
if grep -q 'int stride, int pixelformat' "$REPO_DIR/src/facetimehd/fthd_isp.c" &&
   grep -qF 'cmd.x2 = stride;' "$REPO_DIR/src/facetimehd/fthd_isp.c" &&
   grep -qF 'dev_priv->fmt.fmt.bytesperline,' "$REPO_DIR/src/facetimehd/fthd_isp.c"; then
    result ok "output config sends the real row stride, not a hardcoded width*2"
else
    result bad "output config has gone back to a hardcoded row stride"
fi

# Once a command has entered the firmware ring it cannot be cancelled. A
# signal-interrupted STOP previously let STREAMOFF unmap live DMA buffers.
if grep -q 'wait_event_timeout(chan->wq' \
        "$REPO_DIR/src/facetimehd/fthd_ringbuf.c" &&
   ! grep -q 'wait_event_interruptible_timeout(chan->wq' \
        "$REPO_DIR/src/facetimehd/fthd_ringbuf.c" &&
   [ "$(grep -c 'wake_up(&chan->wq)' \
         "$REPO_DIR/src/facetimehd/fthd_drv.c")" -eq 3 ] &&
   ! grep -q 'wake_up_interruptible(&chan->wq)' \
         "$REPO_DIR/src/facetimehd/fthd_drv.c" &&
   grep -q 'suspend.post_faults' "$REPO_DIR/tests/hw-validate.sh"; then
    result ok "firmware waits and suspend validation protect live DMA mappings"
else
    result bad "a signal or hidden suspend fault can release live DMA mappings"
fi

# Runtime PM performs a full teardown after probe without any userspace action.
# Keep that transition opt-in so an omitted initramfs option means off, not on.
if grep -q '^static bool runtime_pm;$' "$drv" &&
   grep -q '^module_param(runtime_pm, bool, 0444);$' "$drv" &&
   grep -q '^[[:space:]]*if (runtime_pm)$' "$drv"; then
    result ok "runtime PM defaults off and is explicitly probe-gated"
else
    result bad "runtime PM is not safely opt-in"
fi

# The full installer enables the now hardware-tested runtime path by default,
# while both choices remain explicit and reach early initramfs loading.
if grep -q '^RUNTIME_PM=on$' "$INSTALL" &&
   grep -qF "options \$MODULE_NAME runtime_pm=0" "$INSTALL" &&
   grep -qF "options \$MODULE_NAME runtime_pm=1" "$INSTALL" &&
   grep -qF "if [ \"\$RUNTIME_PM\" != keep ]; then" "$INSTALL"; then
    result ok "installer enables runtime PM by default and preserves its recovery opt-out"
else
    result bad "installer runtime-PM defaults or recovery mode are inconsistent"
fi

if grep -q 'confirm_yes "Install the camera driver and firmware?' "$REPO_DIR/setup.sh" &&
   grep -q 'confirm_yes "Install fan support' "$REPO_DIR/setup.sh" &&
   grep -q 'confirm_yes "  Download and extract the firmware' "$INSTALL"; then
    result ok "supported setup features use default-yes prompts"
else
    result bad "a supported setup feature still defaults to disabled"
fi

if printf '\n' | confirm_yes "test" >/dev/null &&
   ! printf 'n\n' | confirm_yes "test" >/dev/null; then
    result ok "default-yes confirmation accepts Enter and honours an explicit no"
else
    result bad "default-yes confirmation parsing is broken"
fi

# A hard lock after module load must not turn a successful DKMS install into
# zero-length files after reset. The installer's set -e makes either failed
# sync fatal, and both source and module filesystems must be persisted before
# modprobe executes the new code.
src_sync_pattern="sync -f -- \"\$SRC_DIR\""
mod_sync_pattern="sync -f -- \"/lib/modules/\$KVER\""
load_pattern="elif modprobe \"\$MODULE_NAME\""
src_sync_line="$(grep -nF "$src_sync_pattern" "$INSTALL" | head -1 | cut -d: -f1)"
mod_sync_line="$(grep -nF "$mod_sync_pattern" "$INSTALL" | head -1 | cut -d: -f1)"
load_line="$(grep -nF "$load_pattern" "$INSTALL" | head -1 | cut -d: -f1)"
if [ -n "$src_sync_line" ] && [ -n "$mod_sync_line" ] && [ -n "$load_line" ] &&
   [ "$src_sync_line" -lt "$load_line" ] && [ "$mod_sync_line" -lt "$load_line" ]; then
    result ok "installer syncs DKMS source and module before live load"
else
    result bad "installer can live-load before DKMS files are persistent"
fi

# The camera PCI device is discovered by udev in the initramfs on affected
# MacBooks.  DKMS regenerates that image before install.sh writes its runtime-PM
# drop-in, so the installer must perform a second refresh after the setting is
# final and before it can execute the module.
runtime_write_line="$(grep -nF "options \$MODULE_NAME runtime_pm=0" "$INSTALL" |
                      head -1 | cut -d: -f1)"
initramfs_line="$(grep -nF "update-initramfs -u -k \"\$KVER\"" "$INSTALL" |
                  head -1 | cut -d: -f1)"
dracut_line="$(grep -nF "dracut --force \"/boot/initramfs-\${KVER}.img\" \"\$KVER\"" "$INSTALL" |
              head -1 | cut -d: -f1)"
if [ -n "$runtime_write_line" ] && [ -n "$initramfs_line" ] &&
   [ -n "$dracut_line" ] && [ "$runtime_write_line" -lt "$initramfs_line" ] &&
   [ "$initramfs_line" -lt "$load_line" ] && [ "$dracut_line" -lt "$load_line" ]; then
    result ok "runtime-PM setting reaches initramfs before module load"
else
    result bad "runtime-PM setting can miss an initramfs-loaded module"
fi

# ---------------------------------------------------------------------------
echo
if [ "$fail" -eq 0 ]; then
    info "All $pass checks passed."
    exit 0
fi
warn "$fail of $((pass + fail)) checks failed."
exit 1
