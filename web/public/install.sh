#!/bin/bash
#
# MacID installer.
#
#   curl -fsSL https://macid.akshith.io/install.sh | bash
#
# Downloads the source, builds it, and wires it into the lock screen.
# Source rather than prebuilt binaries on purpose: this installs a PAM module
# into your authentication stack, and "download an unsigned binary and let it
# decide who can log in" is not a trade worth making.

set -euo pipefail

ORIGIN="${MACID_ORIGIN:-https://macid.akshith.io}"
TARBALL="${MACID_TARBALL:-macid-latest.tar.gz}"
WORKDIR="$(mktemp -d /tmp/macid-install.XXXXXX)"

bold()  { printf '\033[1m%s\033[0m\n' "$1"; }
info()  { printf '  %s\n' "$1"; }
warn()  { printf '\033[33m  !! %s\033[0m\n' "$1"; }
die()   { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

cleanup() {
	local code=$?
	if (( code == 0 )); then
		rm -rf "$WORKDIR"
	else
		printf '\033[33m\nleft the work tree at %s for diagnosis\033[0m\n' "$WORKDIR" >&2
		[[ -f "$WORKDIR/build.log" ]] && printf '  build log: %s/build.log\n' "$WORKDIR" >&2
	fi
}
trap cleanup EXIT

bold "MacID — face unlock for the macOS lock screen"
echo

# --- preflight ---------------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."

MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
info "macOS $MACOS_VERSION ($(uname -m))"

if (( MACOS_MAJOR < 14 )); then
	die "needs macOS 14 or newer, found $MACOS_VERSION"
fi

# The lock screen PAM stack is not API. It moved between releases before and it
# will again, so a version we have not tested gets a warning, not silence.
if (( MACOS_MAJOR > 26 )); then
	warn "macOS $MACOS_MAJOR is newer than this was tested against (26)."
	warn "If face unlock does nothing, run the probe: sudo ./scripts/probe.sh go"
fi

[[ -f /etc/pam.d/screensaver_new ]] || \
	die "/etc/pam.d/screensaver_new not found — this macOS uses a different auth stack. Run scripts/probe.sh to find which."

if ! xcode-select -p >/dev/null 2>&1; then
	die "Xcode command line tools required. Install with: xcode-select --install"
fi
command -v swift >/dev/null 2>&1 || die "swift not found (install Xcode command line tools)"
info "toolchain ok"

# --- fetch -------------------------------------------------------------------

echo
bold "Downloading"
URL="$ORIGIN/$TARBALL"
info "$URL"
curl -fsSL "$URL" -o "$WORKDIR/macid.tar.gz" || die "download failed from $URL"
tar -xzf "$WORKDIR/macid.tar.gz" -C "$WORKDIR" || die "could not extract archive"
info "$(du -h "$WORKDIR/macid.tar.gz" | cut -f1) extracted"

# --- build -------------------------------------------------------------------

echo
bold "Building"
info "this takes a minute"
( cd "$WORKDIR" && make ) >"$WORKDIR/build.log" 2>&1 || {
	echo >&2
	tail -40 "$WORKDIR/build.log" >&2
	die "build failed — full log at $WORKDIR/build.log"
}
info "built"

# --- install -----------------------------------------------------------------

echo
bold "Installing"
info "needs sudo: writes /opt/macid and edits /etc/pam.d/screensaver_new"
info "your existing stack is backed up to screensaver_new.macid-backup"
echo

if ! sudo make -C "$WORKDIR" install; then
	die "install step failed (see the output above)"
fi

# --- next steps --------------------------------------------------------------

cat <<'DONE'

Installed.

  1. Enroll your face       macid enroll
     (this is when macOS asks for camera permission — allow it)

  2. Check it works         macid test

  3. Lock the screen, then press Return on the empty password field.

  Menu bar app              open -a MacID
  Remove everything         sudo macid uninstall

A note on what this is: recognition runs on a 2D webcam, and the liveness
defense is a required blink. That stops a photo. It will not stop a video of
you. It is a convenience over typing, not an upgrade over your password.

DONE
