#!/bin/bash
#
# probe.sh — install/remove the diagnostic PAM module, safely.
#
#   ./probe.sh arm             arm the empty-Return unlock test (5 min, then self-expires)
#   ./probe.sh disarm          undo arm
#   ./probe.sh go               do everything and watch the log (start here)
#   ./probe.sh preflight        check the escape hatch before touching anything
#   ./probe.sh install sudo    add to /etc/pam.d/sudo only (recoverable)
#   ./probe.sh install <stack> [--trigger]
#                              add to one /etc/pam.d stack by name
#   ./probe.sh remove sudo|screensaver|all
#   ./probe.sh log              tail the probe log
#
set -euo pipefail

PAMDIR=/usr/local/lib/pam
MODULE="$PAMDIR/pam_macidprobe.so"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
MARK="# added by MacID probe"
TRIGGER=/var/db/macid-approve
# Every module name this project has shipped under. The probe was pam_faceprobe
# before the rename, so matching only the current name would strand lines that
# an older build of this very script wrote.
OURS='pam_macidprobe|pam_macid\.so|pam_faceprobe|pam_face\.so'
# Likewise for backups: .faceid-backup predates the rename.
BACKUP_SUFFIXES=(".macid-backup" ".faceid-backup")

die() { echo "error: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "run this with sudo"; }

preflight() {
	local ok=1
	echo "== escape hatch check =="

	local rl
	rl=$(systemsetup -getremotelogin 2>/dev/null | tr -d '\n' || true)
	echo "  $rl"
	if [[ "$rl" != *"On"* ]]; then
		echo "  !! Remote Login is OFF. If the lock screen breaks you have no way back in"
		echo "     except Recovery. Turn it on: System Settings > General > Sharing >"
		echo "     Remote Login, or: sudo systemsetup -setremotelogin on"
		ok=0
	fi

	if [[ -f /etc/pam.d/screensaver.macid-backup ]]; then
		echo "  backup of screensaver exists: OK"
	else
		echo "  no screensaver backup yet (created automatically on install)"
	fi

	echo
	echo "== recovery cheat sheet =="
	echo "  From another machine:  ssh $SUDO_USER@\$(hostname)"
	echo "  Then:                  sudo $SRC/scripts/probe.sh remove all"
	echo "  Or by hand:            sudo cp /etc/pam.d/screensaver.macid-backup \\"
	echo "                                 /etc/pam.d/screensaver"
	echo
	[[ $ok -eq 1 ]] && echo "preflight: OK" || { echo "preflight: NOT READY"; exit 1; }
}

install_module() {
	need_root
	[[ -f "$SRC/build/pam_macidprobe.so" ]] || die "not built — run: make"
	install -d -o root -g wheel -m 755 "$PAMDIR"
	install -o root -g wheel -m 644 "$SRC/build/pam_macidprobe.so" "$MODULE"
	# the module is loaded by root processes; nobody but root may replace it
	chown root:wheel "$MODULE"
	chmod 644 "$MODULE"
	echo "installed $MODULE"
}

add_to() {
	local svc="$1" args="${2:-}" control="${3:-optional}"
	local file="/etc/pam.d/$svc"
	[[ -f "$file" ]] || die "$file not found"

	if grep -q "pam_macidprobe" "$file"; then
		echo "$svc: already present, removing old line first"
		remove_from "$svc"
	fi

	[[ -f "$file.macid-backup" ]] || {
		cp -p "$file" "$file.macid-backup"
		echo "$svc: backed up to $file.macid-backup"
	}

	# inserted as the first auth line so we are consulted before
	# opendirectory consumes the token. 'optional' (the default) can neither
	# deny nor grant; 'sufficient' is the armed form used by `arm`.
	local line="auth       $control       $MODULE $args $MARK"
	local tmp
	tmp=$(mktemp)
	awk -v l="$line" '
		!done && /^auth[ \t]/ { print l; done=1 }
		{ print }
		END { if (!done) print l }
	' "$file" > "$tmp"
	cat "$tmp" > "$file"
	rm -f "$tmp"
	chmod 644 "$file"; chown root:wheel "$file"
	echo "$svc: added ->"
	grep -n "macidprobe" "$file" | sed 's/^/    /'
}

remove_from() {
	local svc="$1" file="/etc/pam.d/$svc" suffix backup=""
	[[ -f "$file" ]] || return 0

	for suffix in "${BACKUP_SUFFIXES[@]}"; do
		[[ -f "$file$suffix" ]] && { backup="$file$suffix"; break; }
	done

	if ! grep -Eq "$OURS" "$file"; then
		echo "$svc: nothing to remove"
	elif [[ -n "$backup" ]]; then
		# Restoring beats filtering: it puts back the exact stack Apple shipped,
		# including anything a filter would not know to repair.
		cat "$backup" > "$file"
		echo "$svc: restored from $(basename "$backup")"
	else
		local tmp; tmp=$(mktemp)
		grep -Ev "$OURS" "$file" > "$tmp"
		cat "$tmp" > "$file"
		rm -f "$tmp"
		echo "$svc: probe lines stripped (no backup found)"
	fi

	chmod 644 "$file"; chown root:wheel "$file"
	rm -f "$TRIGGER" /var/db/faceid-approve
}

arm() {
	need_root
	install_module
	add_to screensaver_new "allow_trigger" "sufficient"
	install -d -o root -g wheel -m 755 "$(dirname "$TRIGGER")"
	: > "$TRIGGER"
	chown root:wheel "$TRIGGER"
	chmod 600 "$TRIGGER"
	echo
	echo "ARMED for 5 minutes. An empty Return at the lock screen now unlocks."
	echo "Disarm: sudo $0 disarm"
}

disarm() {
	need_root
	rm -f "$TRIGGER"
	add_to screensaver_new "" "optional"
	echo "disarmed"
}

go() {
	need_root
	echo "== 1/4 escape hatch =="
	local rl
	rl=$(systemsetup -getremotelogin 2>/dev/null | tr -d '\n' || true)
	echo "  $rl"
	if [[ "$rl" != *"On"* ]]; then
		echo "  !! Remote Login is OFF."
		echo "     The probe below is 'auth optional' and always returns PAM_IGNORE,"
		echo "     so it cannot deny a login. But before you ever use --trigger, run:"
		echo "         sudo systemsetup -setremotelogin on"
	fi

	echo
	echo "== 2/4 build + install =="
	[[ -f "$SRC/build/pam_macidprobe.so" ]] || (cd "$SRC" && make)
	install_module

	echo
	echo "== 3/4 load test =="
	if /usr/bin/python3 -c "import ctypes,sys; ctypes.CDLL('$MODULE'); sys.exit(0)" 2>/dev/null; then
		echo "  module dlopens cleanly and resolves its symbols: OK"
	else
		die "module failed to load — stopping before touching /etc/pam.d"
	fi

	echo
	echo "== 4/4 wiring pam stacks =="
	for svc in sudo screensaver screensaver_new screensaver_la authorization; do
		add_to "$svc" ""
	done

	rm -f /var/tmp/macidprobe.log
	touch /var/tmp/macidprobe.log
	chmod 666 /var/tmp/macidprobe.log
}

cmd="${1:-}"; shift || true
case "$cmd" in
	go) go ;;
	arm) arm ;;
	disarm) disarm ;;
	preflight) preflight ;;
	install)
		svc="${1:-}"; shift || true
		[[ -n "$svc" ]] || die "usage: probe.sh install <stack> [--trigger]"
		need_root
		args=""
		[[ "${1:-}" == "--trigger" ]] && args="allow_trigger"
		install_module
		add_to "$svc" "$args"
		;;
	remove)
		need_root
		case "${1:-}" in
			all) for s in sudo screensaver screensaver_new screensaver_la authorization; do
			         remove_from "$s"
			     done
			     # Take the modules off disk too: an unreferenced probe module
			     # sitting in /usr/local/lib/pam is an invitation to wire it
			     # back in.
			     # OpenPAM refuses to start a stack whose modules are missing,
			     # even optional ones, so a module is only deleted once no live
			     # file in /etc/pam.d names it.
			     for m in pam_macidprobe pam_faceprobe; do
			         [[ -f "$PAMDIR/$m.so" ]] || continue
			         if grep -l "$m.so" /etc/pam.d/* 2>/dev/null | grep -qv -- '-backup$'; then
			             echo "kept $PAMDIR/$m.so: still named by a stack in /etc/pam.d"
			         else
			             rm -f "$PAMDIR/$m.so"; echo "removed $PAMDIR/$m.so"
			         fi
			     done
			     echo "done — all probe lines and modules removed" ;;
			"")  die "usage: probe.sh remove sudo|screensaver|all" ;;
			*)   remove_from "$1" ;;
		esac
		;;
	log) touch /var/tmp/macidprobe.log 2>/dev/null || true; tail -f /var/tmp/macidprobe.log ;;
	*) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
