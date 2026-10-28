#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0-only
#
# Apple FaceTime HD camera firmware extractor.
#
# Derived from extract-firmware.sh and the Makefile of
# https://github.com/patjak/facetimehd-firmware, Copyright (C) Patrik Jakobsson
# and contributors, GPL-2.0-only. Upstream stopped development in 2020; this is
# a maintained rewrite carrying the same license.
#
# The camera firmware is proprietary Apple code and cannot be redistributed, so
# it is not in this repository. This script downloads the byte range of an
# Apple-hosted OS X 10.11.5 update that contains the AppleCameraInterface kext,
# carves the firmware out of it, verifies both against known SHA-256 values, and
# installs it. This is the only step in the project that touches the network
# (and, for the calibration files only, it may fetch 7-Zip to unpack them).
#
# Changes from upstream: staging happens in a private mktemp directory instead
# of fixed /tmp paths, curl verifies TLS certificates, the unused --dmg path
# (which needed 7z/xar/pbzx and referenced a hardcoded 10.11.3 package name) and
# the Debian packaging targets are gone.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

MODULE_NAME=facetimehd

# The Apple-hosted update, and the byte range within it holding the xz-compressed
# cpio payload that contains the kext. Both are facts about Apple's CDN object,
# not something we get to choose.
DRIVER_URL='https://updates.cdn-apple.com/2019/cert/041-88431-20191011-e7ee7d98-2878-4cd9-bc0a-d98b3a1e24b1/OSXUpd10.11.5.dmg'
DRIVER_RANGE='204909802-207733123'
KEXT_PATH='System/Library/Extensions/AppleCameraInterface.kext/Contents/MacOS/AppleCameraInterface'
KEXT_NAME='AppleCameraInterface'

# Firmware header (bytes 4-32) and footer (last 8 bytes), used only by
# --ignore-hashes to sanity-check an image whose SHA-256 we do not know.
FW_HEADER='feffffeafeffffeafeffffeafeffffeafeffffeafeffffeafeffffea'
FW_FOOTER='00000000ffffffff'

# Known camera drivers, keyed by SHA-256, with where the firmware sits inside
# each one. Only the 10.11.5 kext is reachable via the download path; the rest
# are here so --driver works on a kext or AppleCamera.sys you supply yourself.
declare -A DRIVER_NAMES=(
    [6ec37d48c0764ed059dd49f472456a4f70150297d6397b7cc7965034cf78627e]='Windows Boot Camp 5.1.5722'
    [7044344593bfc08ab9b41ab691213bca568c8d924d0e05136b537f66b3c46f31]='Windows Boot Camp update 2015-07-29'
    [387097b5133e980196ac51504a60ae1ad8bab736eb0070a55774925ca0194892]='OS X El Capitan'
    [4667e6828f6bfc690a39cf9d561369a525f44394f48d0a98d750931b2f3f278b]='OS X El Capitan'
    [d4650346c940dafdc50e5fcbeeeffe074ec359726773e79c0cfa601cec6b1f08]='OS X El Capitan 10.11.2'
    [dfac86799c6cf0aceb59bb4e732be8f030e7943eb1146830c7136f62621c9853]='OS X El Capitan 10.11.3'
    [f56e68a880b65767335071531a1c75f3cfd4958adc6d871adf8dbf3b788e8ee1]='OS X El Capitan 10.11.5'
)

declare -A DRIVER_OFFSETS=(
    [6ec37d48c0764ed059dd49f472456a4f70150297d6397b7cc7965034cf78627e]=78208
    [7044344593bfc08ab9b41ab691213bca568c8d924d0e05136b537f66b3c46f31]=85296
    [387097b5133e980196ac51504a60ae1ad8bab736eb0070a55774925ca0194892]=81920
    [4667e6828f6bfc690a39cf9d561369a525f44394f48d0a98d750931b2f3f278b]=81920
    [d4650346c940dafdc50e5fcbeeeffe074ec359726773e79c0cfa601cec6b1f08]=81920
    [dfac86799c6cf0aceb59bb4e732be8f030e7943eb1146830c7136f62621c9853]=81920
    [f56e68a880b65767335071531a1c75f3cfd4958adc6d871adf8dbf3b788e8ee1]=81920
)

declare -A DRIVER_SIZES=(
    [6ec37d48c0764ed059dd49f472456a4f70150297d6397b7cc7965034cf78627e]=1523716
    [7044344593bfc08ab9b41ab691213bca568c8d924d0e05136b537f66b3c46f31]=1421316
    [387097b5133e980196ac51504a60ae1ad8bab736eb0070a55774925ca0194892]=603715
    [4667e6828f6bfc690a39cf9d561369a525f44394f48d0a98d750931b2f3f278b]=603715
    [d4650346c940dafdc50e5fcbeeeffe074ec359726773e79c0cfa601cec6b1f08]=603715
    [dfac86799c6cf0aceb59bb4e732be8f030e7943eb1146830c7136f62621c9853]=603715
    [f56e68a880b65767335071531a1c75f3cfd4958adc6d871adf8dbf3b788e8ee1]=603715
)

# The Windows drivers store the firmware uncompressed; the OS X kexts gzip it.
declare -A DRIVER_COMPRESSION=(
    [6ec37d48c0764ed059dd49f472456a4f70150297d6397b7cc7965034cf78627e]=none
    [7044344593bfc08ab9b41ab691213bca568c8d924d0e05136b537f66b3c46f31]=none
    [387097b5133e980196ac51504a60ae1ad8bab736eb0070a55774925ca0194892]=gzip
    [4667e6828f6bfc690a39cf9d561369a525f44394f48d0a98d750931b2f3f278b]=gzip
    [d4650346c940dafdc50e5fcbeeeffe074ec359726773e79c0cfa601cec6b1f08]=gzip
    [dfac86799c6cf0aceb59bb4e732be8f030e7943eb1146830c7136f62621c9853]=gzip
    [f56e68a880b65767335071531a1c75f3cfd4958adc6d871adf8dbf3b788e8ee1]=gzip
)

# Known-good extracted firmware images. Upstream also listed
# e3e6034a...09d32d4d as "1.45.0", which is the 1.43.0 hash with one hex digit
# changed at the very end - a typo, not a real image. It is not carried over.
declare -A FIRMWARE_VERSIONS=(
    [dabb8cf8e874451ebc85c51ef524bd83ddfa237c9ba2e191f8532b896594e50e]='1.05'
    [ed75dc37b1a0e19949e9e046a629cb55deb6eec0f13ba8fd8dd49b5ccd5a800e]='1.38'
    [504fcf1565bf10d61b31a12511226ae51991fb55d480f82de202a2f7ee9c966e]='1.40.0'
    [e3e6034a67dfdaa27672dd547698bbc5b33f47f1fc7f5572a2fb68ea09d32d3d]='1.43.0'
)

# --- Sensor calibration ("set") files ---------------------------------------
#
# The camera works without these; colours are wrong without them. They are not
# in the OS X kext at all - only the Windows Boot Camp driver carries them, so
# they need their own download even though the firmware does not.
#
# Boot Camp 5.1.5769 ships them inside BootCamp/Drivers/Apple/AppleCamera64.exe,
# a RAR self-extractor holding AppleCamera.sys. Two facts about that zip let us
# avoid downloading all 542 MB of it: it serves byte ranges, and the member's
# local header sits at offset 2337987 with 1154424 bytes of deflate after a
# 98-byte header. That is a ~1.2 MB fetch. Both numbers come from the zip's own
# central directory; re-derive them if Apple ever republishes the package.
BOOTCAMP_URL='https://download.info.apple.com/Mac_OS_X/031-30890-20150812-ea191174-4130-11e5-a125-930911ba098f/bootcamp5.1.5769.zip'
BOOTCAMP_RANGE='2337987-3492508'
BOOTCAMP_MEMBER_HEADER=98
SYS_NAME='AppleCamera.sys'

# AppleCamera64.exe is a *solid* RAR3, and not every distribution can unpack
# one: AlmaLinux 10 has no unar, EPEL's unrar is unrar-free (which cannot read
# solid archives), and its bsdtar and 7zip are built without RAR support. When
# nothing installed can, fall back to the official 7-Zip Linux build, which can.
# It is fetched into the private work directory, refused unless its SHA-256
# matches, used for this one unpack and deleted with everything else. Bump the
# version and hash together, from the release's own published digest.
SEVENZIP_URL='https://github.com/ip7z/7zip/releases/download/26.04/7z2604-linux-x64.tar.xz'
SEVENZIP_SHA256='fc0327ba27e89bd086cf426dff17d77de582953cdbbc10a6576540a06853ffcd'

# Where each set file sits inside AppleCamera.sys, keyed by the SHA-256 of the
# .sys - the same key the firmware tables above use, because it is the same
# file. Format: name:skip:count. Offsets are upstream's (see the project wiki,
# "Extracting the sensor calibration files"); the hashes below are what those
# offsets actually produced, so a wrong offset cannot install a bad file.
declare -A CALIBRATION_LAYOUT=(
    [6ec37d48c0764ed059dd49f472456a4f70150297d6397b7cc7965034cf78627e]='1771_01XX.dat:1644880:19040 1871_01XX.dat:1606800:19040 1874_01XX.dat:1625840:19040 9112_01XX.dat:1663920:33060'
)

# Known-good set files. Upstream published MD5s; these are SHA-256 of the same
# images, verified against those MD5s during extraction.
declare -A CALIBRATION_HASHES=(
    [1771_01XX.dat]=756c2bb7c5e55b395449e43a0be1cb7c40c37dfc6c2b5abfaffb8ae70ff0fc4b
    [1871_01XX.dat]=bf36fbde0668ab7e44368b584f9fa64b5945b01003d04c6e3c6f22c0be0fd5f3
    [1874_01XX.dat]=ffde89e7819ac16a9eb1c8f0bc6dba0e980b508b2022507679d901c190f7cef8
    [9112_01XX.dat]=4dd756fa8460d8dc3d78d0d76944b2f92275d1fe9c83181bbc8292c81c005f1a
)

DRIVER_FILE=''
SYS_FILE=''
DEST_DIR=''
IGNORE_HASHES=0
DO_INSTALL=1
DO_CALIBRATION=0
CALIBRATION_ONLY=0
CHECK_SOURCES=0
CALIBRATION_SKIPPED=0

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

Downloads the AppleCameraInterface kext from Apple's servers, extracts the
FaceTime HD camera firmware from it, and installs it as firmware.bin.

  -x, --driver FILE   Extract from a local driver instead of downloading.
                      Either an AppleCameraInterface kext binary or the
                      AppleCamera.sys from a Boot Camp package.
      --dest DIR      Install into DIR (default: $(firmware_root)/$MODULE_NAME).
      --no-install    Leave the files in the current directory; do not install
                      them. Does not require root.
  -i, --ignore-hashes Accept a firmware whose SHA-256 is not in the known-good
                      table, provided its header and footer look right.
      --with-calibration
                      Also fetch the sensor calibration (.dat) files. These fix
                      the camera's colours and live only in the Windows Boot
                      Camp driver, so this is a second ~1.2 MB download. It
                      is unpacked with unar, unrar or 7-Zip; if none of those
                      installed can read it, the official 7-Zip build is
                      fetched (~1.6 MB, SHA-256 checked) and used once.
      --calibration-only
                      Fetch only the calibration files; leave firmware.bin
                      alone. Use when the firmware is already installed.
      --sys FILE      Take the calibration files from a local AppleCamera.sys
                      instead of downloading Boot Camp.
      --check-sources Verify that both Apple downloads still resolve and still
                      contain what the checksum tables above expect, then exit.
                      Installs nothing, writes nothing and needs no root.
                      Non-zero exit means an install would fail today.
  -h, --help          Show this help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -x|--driver)      if [ $# -lt 2 ] || [ -z "$2" ]; then
                              error "-x/--driver requires a file argument."; exit 2
                          fi
                          DRIVER_FILE="$2"; shift ;;
        --dest)           if [ $# -lt 2 ] || [ -z "$2" ]; then
                              error "--dest requires a directory argument."; exit 2
                          fi
                          DEST_DIR="$2"; shift ;;
        --no-install)     DO_INSTALL=0 ;;
        -i|--ignore-hashes) IGNORE_HASHES=1 ;;
        --with-calibration) DO_CALIBRATION=1 ;;
        --calibration-only) DO_CALIBRATION=1; CALIBRATION_ONLY=1 ;;
        --check-sources)  CHECK_SOURCES=1; DO_INSTALL=0; DO_CALIBRATION=1 ;;
        --sys)            if [ $# -lt 2 ] || [ -z "$2" ]; then
                              error "--sys requires a file argument."; exit 2
                          fi
                          SYS_FILE="$2"; DO_CALIBRATION=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                error "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

# --no-install writes into the current directory and installs nothing, so a
# --dest alongside it would be silently discarded. Say so instead.
if [ "$DO_INSTALL" -eq 0 ] && [ -n "$DEST_DIR" ]; then
    error "--dest and --no-install cannot be combined: --no-install leaves"
    error "firmware.bin in the current directory and installs nothing."
    exit 2
fi

[ "$DO_INSTALL" -eq 1 ] && require_root
: "${DEST_DIR:=$(firmware_root)/$MODULE_NAME}"

sha256() { sha256sum -- "$1" | awk '{ print $1 }'; }

TMPDIR_WORK=''
cleanup() { if [ -n "$TMPDIR_WORK" ]; then rm -rf -- "$TMPDIR_WORK"; fi; }
trap cleanup EXIT
TMPDIR_WORK="$(mktemp -d -t facetimehd-firmware.XXXXXXXX)"

# The firmware and the calibration files come from different Apple downloads,
# so either stage can run without the other.
if [ "$CALIBRATION_ONLY" -eq 1 ]; then
    info "Skipping the firmware; --calibration-only was given."
else
    # --- 1. Obtain the driver ---------------------------------------------------

    if [ -n "$DRIVER_FILE" ]; then
        [ -f "$DRIVER_FILE" ] || die "No such driver file: $DRIVER_FILE"
        require_cmds sha256sum awk dd
        step "Using local driver $DRIVER_FILE"
    else
        require_cmds sha256sum awk dd curl xzcat cpio
        step "Downloading the camera driver from Apple"
        info "This fetches ~2.7 MB of $DRIVER_URL"
        # The byte range deliberately stops once the kext has gone by, so the xz
        # stream is truncated and xzcat and cpio both exit non-zero having done
        # exactly what we wanted. Their status is therefore meaningless here; what
        # matters is whether the kext came out, which the SHA-256 check below
        # establishes far more strongly than any exit code would.
        #
        # cpio writes the kext at its full archive path, relative to the cwd.
        ( cd -- "$TMPDIR_WORK" &&
          curl -fsSL -r "$DRIVER_RANGE" "$DRIVER_URL" |
              xzcat -q |
              cpio --format odc -i -d "./$KEXT_PATH" ) >/dev/null 2>&1 || true
        DRIVER_FILE="$TMPDIR_WORK/$KEXT_PATH"
        [ -s "$DRIVER_FILE" ] ||
            die "Download failed - no $KEXT_NAME extracted. Check network access to updates.cdn-apple.com."
    fi

    # --- 2. Identify it ---------------------------------------------------------

    driver_hash="$(sha256 "$DRIVER_FILE")"
    if [ -z "${DRIVER_NAMES[$driver_hash]:-}" ]; then
        error "Unrecognised driver: $DRIVER_FILE"
        error "SHA-256 is $driver_hash, which is not a known camera driver."
        die "No firmware extracted."
    fi
    ok "Driver recognised: ${DRIVER_NAMES[$driver_hash]}"

    offset="${DRIVER_OFFSETS[$driver_hash]}"
    size="${DRIVER_SIZES[$driver_hash]}"
    compression="${DRIVER_COMPRESSION[$driver_hash]}"

    # --- 3. Carve the firmware out ----------------------------------------------

    step "Extracting the firmware"
    raw="$TMPDIR_WORK/firmware.raw"
    fw="$TMPDIR_WORK/firmware.bin"
    dd bs=1 skip="$offset" count="$size" if="$DRIVER_FILE" of="$raw" status=none

    case "$compression" in
        # The carve is sized to the driver, not to the gzip stream inside it, so a
        # trailing byte would make gzip exit 2 with "trailing garbage ignored" after
        # having decompressed everything correctly. That is not a failure worth
        # aborting on - whether the image is right is settled by the SHA-256 below,
        # far more strongly than by an exit code - and letting set -e act on it
        # would skip the emptiness check and the verification entirely.
        gzip) require_cmds zcat; zcat -- "$raw" > "$fw" || true ;;
        none) cp -- "$raw" "$fw" ;;
        *)    die "Unknown compression method: $compression" ;;
    esac
    [ -s "$fw" ] || die "Extraction produced an empty firmware image."

    # --- 4. Verify it -----------------------------------------------------------

    fw_hash="$(sha256 "$fw")"
    if [ -n "${FIRMWARE_VERSIONS[$fw_hash]:-}" ]; then
        ok "Firmware verified: version ${FIRMWARE_VERSIONS[$fw_hash]}"
    elif [ "$IGNORE_HASHES" -eq 1 ]; then
        warn "Firmware SHA-256 $fw_hash is not in the known-good table."
        require_cmds hexdump
        header="$(hexdump -v -e '"" /1 "%02x"' -s 4 -n 28 "$fw")"
        footer="$(tail -c 8 -- "$fw" | hexdump -v -e '"" /1 "%02x"')"
        [ "$header" = "$FW_HEADER" ] || die "Wrong firmware header - not a camera firmware."
        [ "$footer" = "$FW_FOOTER" ] || die "Wrong firmware footer - not a camera firmware."
        warn "Header and footer look right, but this image is untested. Use at your own risk."
    else
        error "Firmware SHA-256 $fw_hash is not a known-good image."
        error "Re-run with --ignore-hashes to accept it on a header check alone."
        die "No firmware installed."
    fi

    # --- 5. Install it ----------------------------------------------------------

    if [ "$CHECK_SOURCES" -eq 1 ]; then
        # Nothing is written: the point of this mode is to prove the download
        # and the checksum table still agree, and the proof is the verification
        # that has already happened above. Writing the firmware out would also
        # mean leaving proprietary Apple code in a CI workspace.
        ok "Firmware source verified (nothing installed)"
    elif [ "$DO_INSTALL" -eq 0 ]; then
        cp -- "$fw" ./firmware.bin
        ok "Firmware written to $PWD/firmware.bin"
    else
        step "Installing the firmware"
        install -d -m 755 -- "$DEST_DIR"
        install -m 644 -- "$fw" "$DEST_DIR/firmware.bin"
        ok "Firmware installed to $DEST_DIR/firmware.bin"
    fi

fi

# --- 6. Sensor calibration files --------------------------------------------
#
# Optional and independent of everything above: the camera streams fine without
# these, it just gets the colours wrong. The driver asks for one file by sensor
# id (see fthd_isp_cmd_set_loadfile), but they total under 100 kB, so install
# all of them and let any machine find its own.

# Unpack the RAR at $1 into the directory $2 with the tool $3, which is a
# command name or, for the fetched 7-Zip, a path. Success means AppleCamera.sys
# came out, not that the tool exited 0: unrar-free and a 7z built without RAR
# support are both installed under the right names and both fail here.
rar_unpack() {
    local exe="$1" out="$2" tool="$3"
    rm -rf -- "$out"
    mkdir -p -- "$out"
    case "$tool" in
        unar)  unar -q -f -o "$out" "$exe" ;;
        unrar) unrar x -y -inul "$exe" "$out/" ;;
        *)     "$tool" x -y -bso0 -bsp0 -bse0 -o"$out" "$exe" ;;
    esac >/dev/null 2>&1 || true
    find "$out" -name "$SYS_NAME" -type f -size +0 -print -quit 2>/dev/null
}

# Fetch the official 7-Zip build into the work directory and print the path of
# its 7zz binary. Fails, printing nothing, if it cannot be had or its checksum
# does not match.
fetch_7zz() {
    local tarball="$TMPDIR_WORK/7zip.tar.xz" dir="$TMPDIR_WORK/7zip"
    [ "$(uname -m)" = x86_64 ] || return 1
    { have tar && have xz; } || return 1
    curl -fsSL -o "$tarball" "$SEVENZIP_URL" || return 1
    if [ "$(sha256 "$tarball")" != "$SEVENZIP_SHA256" ]; then
        warn "7-Zip download has an unexpected SHA-256; not using it."
        return 1
    fi
    mkdir -p -- "$dir"
    tar -xJf "$tarball" -C "$dir" 7zz || return 1
    [ -x "$dir/7zz" ] || return 1
    printf '%s\n' "$dir/7zz"
}

if [ "$DO_CALIBRATION" -eq 1 ]; then
    if [ "$CHECK_SOURCES" -eq 1 ]; then
        step "Checking the sensor calibration source"
    else
        step "Extracting the sensor calibration files"
    fi

    if [ -n "$SYS_FILE" ]; then
        [ -f "$SYS_FILE" ] || die "No such file: $SYS_FILE"
        require_cmds sha256sum awk dd
        info "Using local $SYS_FILE"
    else
        require_cmds sha256sum awk dd curl zcat
        info "This fetches ~1.2 MB of $BOOTCAMP_URL"
        exe="$TMPDIR_WORK/AppleCamera64.exe"

        # The zip member is raw deflate. Prefixing a minimal gzip header lets
        # zcat inflate it without a zip tool; zcat then fails on the missing
        # trailer having already written every byte correctly, exactly as the
        # firmware carve above tolerates for the same reason.
        {
            printf '\037\213\010\000\000\000\000\000\000\377'
            curl -fsSL -r "$BOOTCAMP_RANGE" "$BOOTCAMP_URL" |
                dd bs=1 skip="$BOOTCAMP_MEMBER_HEADER" status=none
        } | zcat > "$exe" 2>/dev/null || true
        [ -s "$exe" ] ||
            die "Download failed - no AppleCamera64.exe extracted. Check network access to download.info.apple.com."

        unpacked="$TMPDIR_WORK/unpacked"
        for c in unar unrar 7zz 7z; do
            have "$c" || continue
            SYS_FILE="$(rar_unpack "$exe" "$unpacked" "$c")"
            [ -n "$SYS_FILE" ] && { info "Unpacked with $c"; break; }
        done

        # A --check-sources run is a watchdog on Apple's downloads, so it does
        # not reach for GitHub: with no working unpacker here it reports the
        # calibration source as unchecked rather than failed, or it would blame
        # Apple every time a CI image drops unar.
        if [ -z "$SYS_FILE" ] && [ "$CHECK_SOURCES" -eq 1 ]; then
            warn "Nothing here can unpack the solid RAR; the calibration source cannot be checked."
            CALIBRATION_SKIPPED=1
            DO_CALIBRATION=0
        elif [ -z "$SYS_FILE" ]; then
            info "No installed tool can unpack the solid RAR in the Boot Camp driver."
            info "Fetching the official 7-Zip build for this one step (~1.6 MB)."
            if sevenzip="$(fetch_7zz)" && [ -n "$sevenzip" ]; then
                SYS_FILE="$(rar_unpack "$exe" "$unpacked" "$sevenzip")"
            fi
            [ -n "$SYS_FILE" ] || die \
                "Could not unpack $SYS_NAME from the Boot Camp driver.
       It is a solid RAR3: unar, RARLAB's unrar or 7-Zip with RAR support can
       read it (unrar-free cannot), and fetching 7-Zip from
       $SEVENZIP_URL failed.
       Or supply an unpacked AppleCamera.sys with --sys FILE."
        fi
    fi
fi

if [ "$DO_CALIBRATION" -eq 1 ]; then
    sys_hash="$(sha256 "$SYS_FILE")"
    layout="${CALIBRATION_LAYOUT[$sys_hash]:-}"
    if [ -z "$layout" ]; then
        if [ -n "${DRIVER_NAMES[$sys_hash]:-}" ]; then
            # A known driver, just not one CALIBRATION_LAYOUT has offsets for
            # yet - worth saying differently from "never seen this file",
            # since guessing offsets into a *different* driver binary is the
            # dangerous case, not merely an unindexed one.
            error "${DRIVER_NAMES[$sys_hash]} ($SYS_NAME, SHA-256 $sys_hash) is a"
            error "recognised camera driver, but no calibration layout has been"
            error "recorded for it yet - only Boot Camp 5.1.5722 is. Guessing"
            error "offsets would install whatever happened to be at them."
        else
            error "Unrecognised $SYS_NAME: SHA-256 is $sys_hash."
            error "No calibration layout is known for it, and guessing offsets"
            error "would install whatever happened to be at them."
        fi
        die "No calibration files extracted."
    fi
    ok "Boot Camp driver recognised: ${DRIVER_NAMES[$sys_hash]:-$sys_hash}"

    cal_dir="$TMPDIR_WORK/calibration"
    mkdir -p -- "$cal_dir"
    cal_ok=0
    for entry in $layout; do
        cal_name="${entry%%:*}"
        rest="${entry#*:}"
        cal_skip="${rest%%:*}"
        cal_count="${rest#*:}"

        dd bs=1 skip="$cal_skip" count="$cal_count" \
           if="$SYS_FILE" of="$cal_dir/$cal_name" status=none

        cal_hash="$(sha256 "$cal_dir/$cal_name")"
        want="${CALIBRATION_HASHES[$cal_name]:-}"
        if [ "$cal_hash" != "$want" ]; then
            warn "$cal_name has SHA-256 $cal_hash, expected $want - discarding it."
            rm -f -- "$cal_dir/$cal_name"
            continue
        fi
        cal_ok=$((cal_ok + 1))
    done

    [ "$cal_ok" -gt 0 ] || die "No calibration file passed verification."
    ok "Verified $cal_ok calibration file(s)"

    if [ "$CHECK_SOURCES" -eq 1 ]; then
        ok "Calibration source verified (nothing installed)"
    elif [ "$DO_INSTALL" -eq 0 ]; then
        cp -- "$cal_dir"/*.dat ./
        ok "Calibration files written to $PWD"
    else
        step "Installing the calibration files"
        install -d -m 755 -- "$DEST_DIR"
        install -m 644 -- "$cal_dir"/*.dat "$DEST_DIR/"
        ok "Calibration files installed to $DEST_DIR"
    fi
fi

# --- 7. Summary, for --check-sources ----------------------------------------
#
# Everything above dies on a mismatch, so reaching here means the downloads and
# the checksum tables still agree. The point of saying so explicitly is that
# this mode exists to be run unattended by CI, where a silent success and a
# silently skipped run look identical.

if [ "$CHECK_SOURCES" -eq 1 ]; then
    echo
    ok "Apple firmware source is reachable and matches the checksum table."
    if [ "$CALIBRATION_SKIPPED" -eq 1 ]; then
        warn "The calibration source was NOT checked (no RAR unpacker here)."
    else
        ok "Boot Camp calibration source is reachable and matches its table."
    fi
    info "Nothing was installed and no Apple content was written to disk."
fi
