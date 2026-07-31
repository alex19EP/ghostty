#!/usr/bin/env bash
#
# Run the GTK accessibility tests against a built Ghostty.
#
#   test/gtk-a11y/run.sh                 # everything
#   test/gtk-a11y/run.sh test_text.py    # one module
#   test/gtk-a11y/run.sh -k hypertext -x # any pytest arguments
#
# Everything runs inside a private X display, a private session bus and a
# private accessibility bus, so this never touches your real desktop, your
# real Ghostty config, or the accessibility bus your screen reader is on.
#
# Requires: Xvfb, dbus-run-session, xdotool, pytest, python-gobject with the
# Atspi typelib, and at-spi2-core.
#
# Set GHOSTTY_A11Y_KEEP=1 to leave each run's temporary state (config,
# Ghostty's stderr) on disk for debugging.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

find_helper() {
	local name="$1" candidate
	for candidate in \
		"/usr/lib/$name" \
		"/usr/libexec/$name" \
		"/usr/lib/at-spi2-core/$name" \
		"/usr/lib/$(uname -m)-linux-gnu/$name"; do
		if [[ -x "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	done
	command -v "$name" 2>/dev/null && return 0
	return 1
}

# --------------------------------------------------------------------------
# Inner half: runs inside `dbus-run-session`, brings up the accessibility bus,
# then runs the tests. Re-invokes this same script rather than shipping a
# second file.
# --------------------------------------------------------------------------
if [[ -n "${GHOSTTY_A11Y_INNER:-}" ]]; then
	launcher="$(find_helper at-spi-bus-launcher)"
	registryd="$(find_helper at-spi2-registryd)"

	"$launcher" --launch-immediately &
	launcher_pid=$!

	a11y_addr=""
	for _ in $(seq 100); do
		a11y_addr="$(gdbus call --session --dest org.a11y.Bus \
			--object-path /org/a11y/bus \
			--method org.a11y.Bus.GetAddress 2>/dev/null || true)"
		[[ -n "$a11y_addr" ]] && break
		sleep 0.1
	done
	if [[ -z "$a11y_addr" ]]; then
		echo "error: at-spi-bus-launcher never claimed org.a11y.Bus" >&2
		exit 1
	fi
	# Unwrap the GVariant tuple: ('unix:path=...',) -> unix:path=...
	a11y_addr="${a11y_addr#\(\'}"
	a11y_addr="${a11y_addr%\',\)}"

	# Start the registry ourselves. It is nominally D-Bus activated, but on
	# systemd distributions org.a11y.atspi.Registry.service hands off to the
	# *user's* systemd instance, which knows nothing about this private bus
	# and fails the activation ("unit failed"). Launching it directly means
	# the name is already owned and no activation is attempted.
	"$registryd" &
	registryd_pid=$!

	inner_cleanup() {
		kill "$registryd_pid" "$launcher_pid" 2>/dev/null || true
		wait "$registryd_pid" "$launcher_pid" 2>/dev/null || true
	}
	trap inner_cleanup EXIT

	ready=""
	for _ in $(seq 100); do
		if gdbus call --address "$a11y_addr" \
			--dest org.freedesktop.DBus \
			--object-path /org/freedesktop/DBus \
			--method org.freedesktop.DBus.NameHasOwner \
			org.a11y.atspi.Registry 2>/dev/null | grep -q true; then
			ready=1
			break
		fi
		sleep 0.1
	done
	if [[ -z "$ready" ]]; then
		echo "error: at-spi2-registryd never came up on $a11y_addr" >&2
		exit 1
	fi

	# Run from the test directory so a bare module name works as documented
	# (`run.sh test_text.py`). Passing "$here" alongside "$@" instead would
	# resolve that name against the caller's cwd and fail to collect.
	cd "$here"
	python3 -m pytest "$@"
	exit $?
fi

# --------------------------------------------------------------------------
# Outer half: binary check, tool check, private X display.
# --------------------------------------------------------------------------
: "${GHOSTTY_BIN:=$root/zig-out/bin/ghostty}"
export GHOSTTY_BIN

if [[ ! -x "$GHOSTTY_BIN" ]]; then
	cat >&2 <<-EOF
		error: no Ghostty at $GHOSTTY_BIN

		Build one first:
		    zig build -Dapp-runtime=gtk

		or point GHOSTTY_BIN at an existing binary.
	EOF
	exit 1
fi

missing=()
for tool in Xvfb dbus-run-session xdotool gdbus; do
	command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
for helper in at-spi-bus-launcher at-spi2-registryd; do
	find_helper "$helper" >/dev/null || missing+=("$helper")
done
if ((${#missing[@]})); then
	echo "error: missing required tools: ${missing[*]}" >&2
	exit 1
fi

if ! python3 -c 'import gi, pytest; gi.require_version("Atspi", "2.0")' 2>/dev/null; then
	echo "error: need pytest and python-gobject with the Atspi 2.0 typelib" >&2
	exit 1
fi

# Private X display. -displayfd makes Xvfb pick a free number and tell us
# which, so a busy desktop or a parallel run does not collide.
displayfd_file="$(mktemp)"
Xvfb -displayfd 3 -screen 0 1280x1024x24 -nolisten tcp 3>"$displayfd_file" &
xvfb_pid=$!

cleanup() {
	kill "$xvfb_pid" 2>/dev/null || true
	wait "$xvfb_pid" 2>/dev/null || true
	rm -f "$displayfd_file"
}
trap cleanup EXIT

display_num=""
for _ in $(seq 100); do
	display_num="$(cat "$displayfd_file")"
	[[ -n "$display_num" ]] && break
	sleep 0.1
done
if [[ -z "$display_num" ]]; then
	echo "error: Xvfb did not come up" >&2
	exit 1
fi
export DISPLAY=":$display_num"

# Ghostty renders through a GtkGLArea and `axNotifyIfChanged` hangs off the
# render callback, so the tests need real frames. Xvfb has no GPU.
export LIBGL_ALWAYS_SOFTWARE=1
export GDK_BACKEND=x11
export GTK_A11Y=atspi

# Opt-in gate read by conftest.py, so a bare `pytest` at the repo root
# collects these as skipped instead of failing without a display.
export GHOSTTY_A11Y_TEST=1

# Deliberately not `exec`: the EXIT trap above has to run to reap Xvfb.
GHOSTTY_A11Y_INNER=1 dbus-run-session -- "$here/run.sh" "$@"
