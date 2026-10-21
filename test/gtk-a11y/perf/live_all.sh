#!/usr/bin/env bash
#
# Three live.py runs in a row against the user's own running Orca: Ghostty
# with links, kgx, Ghostty with links off. Each opens a window that waits
# for Enter, then closes itself once Orca has gone idle.
#
#   test/gtk-a11y/perf/live_all.sh <ghostty binary> <outdir>
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# -ne 2 ]]; then
	echo "usage: $0 <ghostty binary> <outdir>" >&2
	exit 2
fi
g="$(realpath "$1")"
out="$2"
python3 -I "$here/live.py" "ghostty=$g" "$out/links" --perf
sleep 3
python3 -I "$here/live.py" kgx "$out/kgx"
sleep 3
python3 -I "$here/live.py" "ghostty=$g" "$out/nolinks" --nolinks --perf
python3 -I "$here/analyze.py" "$out/links" "$out/kgx" "$out/nolinks"
