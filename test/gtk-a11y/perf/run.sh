#!/usr/bin/env bash
#
# Measure a terminal against a real Orca, privately: its own display,
# session bus, a11y bus, Orca and speech-dispatcher, never the user's.
#
#   test/gtk-a11y/perf/run.sh <terminal> <outdir> [driver options]
#   GPU=1 test/gtk-a11y/perf/run.sh ...    # headless Mutter, real GPU
#
# <terminal> is ghostty=<binary>, kgx or ptyxis. See README.md for the
# driver options and for reading the results with analyze.py.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

if [[ -n "${PERF_INNER:-}" ]]; then
	export GTK_A11Y=atspi
	"$(find_helper at-spi-bus-launcher)" --launch-immediately &
	launcher_pid=$!
	a11y_addr=""
	for _ in $(seq 100); do
		a11y_addr="$(gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
			--method org.a11y.Bus.GetAddress 2>/dev/null || true)"
		[[ -n "$a11y_addr" ]] && break
		sleep 0.1
	done
	a11y_addr="${a11y_addr#\(\'}"
	a11y_addr="${a11y_addr%\',\)}"
	"$(find_helper at-spi2-registryd)" &
	registryd_pid=$!
	trap 'kill $registryd_pid $launcher_pid 2>/dev/null || true' EXIT
	for _ in $(seq 100); do
		gdbus call --address "$a11y_addr" --dest org.freedesktop.DBus \
			--object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner \
			org.a11y.atspi.Registry 2>/dev/null | grep -q true && break
		sleep 0.1
	done
	export A11Y_ADDR="$a11y_addr" REGISTRYD_PID="$registryd_pid"
	python3 -I "$here/driver.py" "$@"
	exit $?
fi

if [[ $# -lt 2 ]]; then
	echo "usage: $0 <ghostty=BINARY|kgx|ptyxis> <outdir> [driver options]" >&2
	exit 2
fi
out="$2"
mkdir -p "$out"
# Short on purpose: unix socket paths are capped at 108 bytes, and the a11y
# bus launcher silently produces "unix:abstract=" when its path won't fit.
rt="$(mktemp -d /tmp/gperf.XXXX)"
chmod 700 "$rt"
trap 'rm -rf "$rt"' EXIT
export XDG_RUNTIME_DIR="$rt"
export PULSE_SERVER=unix:/nonexistent
# BrlAPI's local sockets don't go through XDG_RUNTIME_DIR, so without this
# the private Orca connects to the user's own brltty and its braille display.
export BRLAPI_HOST=:perf-none
export LC_ALL=C.UTF-8 LANG=C.UTF-8
export GSETTINGS_BACKEND=memory
export NO_AT_BRIDGE=0 GTK_A11Y=atspi GDK_BACKEND=x11

# GPU=1: a headless Mutter on the private session bus instead of Xvfb. It
# renders with the real GPU and its Xwayland gives the terminal hardware GL,
# while nothing appears on the user's desktop.
if [[ -n "${GPU:-}" ]]; then
	unset DISPLAY WAYLAND_DISPLAY
	# GTK_A11Y=none keeps mutter-x11-frames, which Mutter spawns with its
	# own environment, off the a11y bus: its frame windows take the
	# activation and Orca never reaches the terminal. The inner script
	# turns a11y back on for everything it starts.
	status=0
	PERF_INNER=1 GTK_A11Y=none dbus-run-session --config-file="$here/session.conf" -- \
		mutter --headless --wayland --virtual-monitor 1280x1024 \
		--wayland-display "wl-perf-$$" -- "$here/run.sh" "$@" || status=$?
	exit $status
fi
export LIBGL_ALWAYS_SOFTWARE=1

dfd="$(mktemp)"
Xvfb -displayfd 3 -screen 0 1280x1024x24 -nolisten tcp 3>"$dfd" &
xvfb_pid=$!
trap 'kill $xvfb_pid 2>/dev/null || true; rm -f "$dfd"; rm -rf "$rt"' EXIT
for _ in $(seq 100); do [[ -s "$dfd" ]] && break; sleep 0.1; done
export DISPLAY=":$(cat "$dfd")"
PERF_INNER=1 dbus-run-session --config-file="$here/session.conf" -- "$here/run.sh" "$@"
