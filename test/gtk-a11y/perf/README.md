# Screen reader performance

Measures what a terminal costs a real Orca: how many calls Orca makes, how
long the terminal takes to answer them, how much CPU Orca and the terminal
burn, and how far Orca falls behind fast output. Every run is compared
against another terminal (kgx or ptyxis, both VTE) under the same workload,
because absolute numbers mean little on their own.

Nothing here is a pass/fail test. It is a measuring tool for changes that
affect what Orca sees.

```sh
zig build -Doptimize=ReleaseFast -Dapp-runtime=gtk -Dstrip=false -p /tmp/gprof
GPU=1 test/gtk-a11y/perf/run.sh ghostty=/tmp/gprof/bin/ghostty /tmp/perf/ghostty --only=flood_fast
GPU=1 test/gtk-a11y/perf/run.sh kgx /tmp/perf/kgx --only=flood_fast
python3 -I test/gtk-a11y/perf/analyze.py /tmp/perf/ghostty /tmp/perf/kgx
```

Use a release build, plus whatever `-fsys=` flags your system needs (on Arch,
at least `-fsys=fontconfig`). Debug builds change the comparison, and
`-Dstrip=false` keeps symbols and frame pointers for `--perf`.

## Two ways to run

**`run.sh` (private, unattended).** It gets its own display, session bus,
a11y bus, Orca and speech-dispatcher, with a logging speech module, so it
never touches your desktop or your screen reader.
- **`GPU=1`** runs a headless Mutter (`mutter --headless --wayland`), and
  the terminal renders on the real GPU through its Xwayland. Prefer this.
- **Without `GPU=1`** it uses Xvfb with software GL. That is fine for call
  counts, but llvmpipe runs on the terminal's main thread and adds
  reply-latency tails of tens of milliseconds that a real GPU doesn't have.

**`live.py` / `live_all.sh` (your own session).** These measure the Orca
you are running, against a window on your real desktop.
- They start or restart nothing on the Orca side. They only watch: a
  passive `dbus-monitor` on the a11y bus, and Orca's CPU time from /proc.
- Each window waits for you to press Enter.
- Keep your hands off the keyboard until the window closes. Flat review in
  particular makes Orca rebuild its review context on every insertion, at
  about 15,000 calls/s against 700/s normally, in any terminal.

## What the private Orca needs

`orca_launch.py` runs `/usr/bin/orca`, or the install prefix in
`ORCA_ROOT`, with its "another Orca is running" check disabled. It is
safe because it lives on separate buses.

**Never pass `--replace`.** That SIGKILLs every Orca of your uid,
including the one you are using.

BrlAPI's sockets don't follow `XDG_RUNTIME_DIR`, so `run.sh` points
`BRLAPI_HOST` at a socket that doesn't exist. Otherwise the private Orca
connects to your own brltty and writes to your braille display. Braille
stays enabled, as it is by default, but has no display.

Two environment variables change the private Orca:

| Variable | Effect |
| --- | --- |
| `ORCA_NO_BRAILLE=1` | Sets `braille/enabled` to false. |
| `ORCA_LINK_STACKS=1` | With `--orca-debug`, writes the Python stack of every `get_all_links_in_range()` and `get_all_links()` call into `orca.log` as `LINK STACK:`. |

Orca gets keys from Mutter's `org.freedesktop.a11y.KeyboardMonitor`, as on
GNOME Wayland:
- **Under Xvfb,** where nothing provides it, `driver.py` registers a fake
  one.
- **Under `GPU=1`,** Mutter owns the name. Keys go in through Mutter's
  RemoteDesktop D-Bus API instead, and Mutter delivers them to both the
  window and Orca. xdotool's XTEST input would only reach Xwayland.

## Driver options

| Option | Effect |
| --- | --- |
| `--only=<phase>` | Run only this phase. Repeat it for several. Phases: `type_cat_40cps`, `type_shell_15cps`, `flood_seq`, `flood_paced` (200 lines/s), `flood_fast` (4,000 lines/s), `flood_burst`. |
| `--nolinks` | Ghostty with `link-url = false`, to separate link cost from everything else. |
| `--perf` | `perf record` the terminal and Orca during floods (`perf-<phase>-{term,orca}.data`). Orca runs with `python3 -X perf`, so its Python frames are named. Needs `perf_event_paranoid` ≤ 2. |
| `--props` | Also log the bodies of `PropertyChange` signals (`props.log`). |
| `--orca-debug` | Orca's debug log (`orca.log`). It slows Orca down a lot, so don't take timings from such a run. |

## Reading the results

`analyze.py` prints, per phase:

- **Orca CPU** and the terminal's per-thread CPU.
- **Orca→terminal calls**, with reply latency (p50, p99, max) and the total
  time Orca spent blocked on replies. `by member` shows which calls.
- **Orca still busy after**: how long Orca kept working after the output
  stopped. This is the lag a user hears.
- **Speech**: utterances (the logging module records each one), key-to-speech
  latency, and key-to-`TextChanged` latency.
- **probe**: a client-side `GetText`/`CharacterCount` every 100 ms. Unlike
  dbus-monitor timestamps, these are not skewed by batched reads.

To profile:

```sh
perf report -i <dir>/perf-flood_fast-term.data --stdio --comms ghostty \
  --percentage relative --children --sort symbol -g none
```

`--comms ghostty` restricts the report to the main thread.

## Files

| File | Contents |
| --- | --- |
| `run.sh` | The private environment: Xvfb or headless Mutter, the buses, the registry. |
| `driver.py` | Starts speech-dispatcher, Orca and the terminal, types, runs the phases, records. |
| `analyze.py` | Summarises run directories. Also works on `live.py` output. |
| `pacer.py` | Writes N build-log-like lines at R lines/s. |
| `orca_launch.py` | Runs Orca next to your own. |
| `session.conf` | A session bus with no activatable services, so nothing auto-starts. |
| `live.py`, `live_all.sh` | Measure your own running Orca in your real session. |
