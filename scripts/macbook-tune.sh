#!/usr/bin/env bash
#
# MacBook Fan Support
#
# Under macOS the SMC runs its own fan curve in firmware; Linux's `applesmc`
# exposes only a very conservative floor, so these chassis sit at 90+ C and
# thermally throttle with the fans barely spinning. `mbpfan` is a small daemon
# that reads `coretemp` and drives the fans itself, with a fan curve of its
# own that is fine as shipped, so this script does not configure it - it only
# makes sure the package is installed and its service is running.
#
# The internal keyboard needs nothing here: `hid_apple` ships in the kernel on
# every distribution this project supports and already loads itself.
#
# This script is optional and independent of install.sh: the camera works
# without it, and it works on a Mac with no camera driver installed.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

STATE_DIR=/var/lib/facetimehd
MBPFAN_ENABLED="$STATE_DIR/mbpfan.enabled-by-us"

# Where no repository carries mbpfan - EPEL has none for EL10 - it is built from
# this upstream release instead, refused unless the tarball's SHA-256 matches.
# Bump the version and hash together.
MBPFAN_VERSION=2.4.0
MBPFAN_URL="https://github.com/linux-on-mac/mbpfan/archive/refs/tags/v$MBPFAN_VERSION.tar.gz"
MBPFAN_SHA256=e1cdcffaba52be215ae40a8568949190866d500d6ae2a1e96b71ab5372f3580b

ASSUME_YES=0
ACTION=apply
DO_FAN=1

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

  -y, --yes       Do not prompt for confirmation.
      --skip-fan  Do not install or enable mbpfan.
      --revert    Disable mbpfan.service, if this script was the one that
                  enabled it. mbpfan itself stays installed.
  -h, --help      Show this help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)   ASSUME_YES=1 ;;
        --skip-fan) DO_FAN=0 ;;
        --revert)   ACTION=revert ;;
        -h|--help)  usage; exit 0 ;;
        *)          error "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

require_root

# ---------------------------------------------------------------------------
# Revert
# ---------------------------------------------------------------------------

if [ "$ACTION" = revert ]; then
    step "Restoring the fan configuration"
    if [ -e "$MBPFAN_ENABLED" ]; then
        systemctl disable --now mbpfan.service >/dev/null 2>&1 || true
        rm -f -- "$MBPFAN_ENABLED"
        ok "mbpfan.service disabled"
        warn "The fans go back to the SMC's own floor, which is what made this"
        warn "machine throttle in the first place. mbpfan is still installed."
    else
        info "mbpfan was already enabled before this script touched it, or was"
        info "never enabled by it - nothing to undo"
    fi
    rmdir -- "$STATE_DIR" 2>/dev/null || true

    echo
    info "Reverted."
    exit 0
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

detect_os
step "Checking MacBook fan support"
info "Distribution: ${OS_PRETTY:-unknown}"

apple_rc=0
is_apple_hardware || apple_rc=$?
case "$apple_rc" in
    0) info "Model:        $(dmi_product_name)" ;;
    2) warn "Cannot read DMI, so this machine could not be identified. mbpfan"
       warn "assumes Apple hardware." ;;
    *) warn "This is not Apple hardware according to DMI ($(dmi_product_name))."
       warn "mbpfan drives applesmc's fan controls and does nothing useful here."
       confirm "  Continue anyway?" || { info "Cancelled."; exit 0; } ;;
esac

if [ "$DO_FAN" -eq 0 ]; then
    step "Skipping the fans (--skip-fan)"
    exit 0
fi

pkg_manager >/dev/null ||
    die "This script installs mbpfan with apt or dnf, and this system has
       neither. Install mbpfan with your own package manager yourself."

# ---------------------------------------------------------------------------
# Fans
# ---------------------------------------------------------------------------

# Build the pinned mbpfan release and install what its 'make install' would,
# plus the systemd unit it ships but does not install. An existing
# /etc/mbpfan.conf is left alone, where 'make install' would overwrite it.
build_mbpfan() {
    local work src rc=0

    pkg_install gcc make tar gzip curl >/dev/null || {
        warn "Could not install the tools to build mbpfan (gcc, make, tar, gzip, curl)."
        return 1
    }

    work="$(mktemp -d -t mbpfan-build.XXXXXXXX)"
    src="$work/mbpfan-$MBPFAN_VERSION"
    (
        set -e
        cd -- "$work"
        curl -fsSL -o mbpfan.tar.gz "$MBPFAN_URL"
        if [ "$(sha256sum mbpfan.tar.gz | awk '{ print $1 }')" != "$MBPFAN_SHA256" ]; then
            echo "mbpfan $MBPFAN_VERSION tarball has an unexpected SHA-256" >&2
            exit 1
        fi
        tar -xzf mbpfan.tar.gz
        make -C "$src" bin/mbpfan >/dev/null

        install -D -m 0755 "$src/bin/mbpfan" /usr/sbin/mbpfan
        [ -e /etc/mbpfan.conf ] || install -D -m 0644 "$src/mbpfan.conf" /etc/mbpfan.conf
        install -D -m 0644 "$src/mbpfan.depend.conf" /usr/lib/modules-load.d/mbpfan.depend.conf
        install -D -m 0644 "$src/mbpfan.service" /usr/lib/systemd/system/mbpfan.service
        install -D -m 0644 "$src/mbpfan.8.gz" /usr/share/man/man8/mbpfan.8.gz
    ) || rc=1
    rm -rf -- "$work"
    [ "$rc" -eq 0 ] || return 1

    # Files written by install(1) take their directory's SELinux label, which
    # is the right one here; restorecon only makes sure of it.
    if have restorecon; then
        restorecon -F /usr/sbin/mbpfan /etc/mbpfan.conf \
            /usr/lib/modules-load.d/mbpfan.depend.conf \
            /usr/lib/systemd/system/mbpfan.service 2>/dev/null || true
    fi
    systemctl daemon-reload 2>/dev/null || true
}

step "Installing mbpfan"

# On Enterprise Linux mbpfan can only come from EPEL, so there is no point
# asking whether it is available before EPEL is switched on. Skipped when
# mbpfan is already here, so a re-run does not reconfigure repositories for
# nothing. Not fatal - pkg_available answers the question honestly either way.
if is_enterprise_linux && ! have mbpfan && ! pkg_installed mbpfan; then
    info "Enterprise Linux: mbpfan can only come from EPEL. Enabling it."
    ensure_epel || warn "Could not enable EPEL; mbpfan is unlikely to be found."
fi

if have mbpfan || pkg_installed mbpfan; then
    info "mbpfan is already installed"
elif ! pkg_available mbpfan; then
    # Ubuntu has it in universe and Fedora in the main repositories, but a
    # derivative may have neither, and EPEL does not rebuild every Fedora
    # package for every Enterprise Linux release. Say so plainly instead of
    # letting the package manager fail with "no match for argument: mbpfan".
    warn "mbpfan is not available in this system's repositories."
    info "It can be built from upstream release $MBPFAN_VERSION instead"
    info "(https://github.com/linux-on-mac/mbpfan, SHA-256 checked)."
    if confirm "  Build and install mbpfan $MBPFAN_VERSION from source?"; then
        step "Building mbpfan $MBPFAN_VERSION"
        if build_mbpfan; then
            ok "mbpfan $MBPFAN_VERSION installed to /usr/sbin/mbpfan"
        else
            error "Building mbpfan failed. To do it by hand:"
            info "  git clone https://github.com/linux-on-mac/mbpfan && cd mbpfan"
            info "  make && sudo make install"
            info "  sudo cp mbpfan.service /etc/systemd/system/ && sudo systemctl daemon-reload"
            info "then re-run this script."
            DO_FAN=0
        fi
    else
        DO_FAN=0
    fi
else
    pkg_refresh
    pkg_install mbpfan || {
        warn "Could not install mbpfan."
        DO_FAN=0
    }
fi

if [ "$DO_FAN" -eq 1 ]; then
    if [ ! -d /sys/devices/platform/applesmc.768 ] &&
       ! compgen -G '/sys/devices/platform/applesmc*' >/dev/null; then
        warn "applesmc did not attach, so there are no fan controls to drive."
        warn "mbpfan will start and find nothing to do. On a real MacBook this"
        warn "usually means the module is blacklisted - check"
        warn "'grep -r applesmc /etc/modprobe.d/'."
    fi

    step "Enabling mbpfan"
    if ! unit_exists mbpfan.service; then
        warn "No mbpfan.service unit found. mbpfan is installed, but you will"
        warn "have to start it yourself (it takes no arguments)."
    else
        # Record that we enabled it, so --revert does not switch off a daemon
        # the user was already running before this script touched anything.
        if [ "$(systemctl is-enabled mbpfan.service 2>/dev/null)" != enabled ]; then
            install -d -m 0755 "$STATE_DIR"
            : > "$MBPFAN_ENABLED"
        fi
        systemctl enable --now mbpfan.service >/dev/null 2>&1 ||
            warn "Could not enable mbpfan.service."
        if systemctl is-active --quiet mbpfan.service; then
            ok "mbpfan.service is running"
        else
            warn "mbpfan.service did not start:"
            systemctl status mbpfan.service --no-pager || true
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
info "MacBook fan support checked."
cat <<EOF

mbpfan is left at its own defaults - not reconfigured by this project. See
/etc/mbpfan.conf (man mbpfan.conf) if you want a different fan curve.

Checking it:
  systemctl status mbpfan.service
  journalctl -u mbpfan -b       # what it decided and why

Undo:
  sudo $0 --revert
EOF
