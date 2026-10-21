"""Measure the user's own running Orca against one terminal in the real session.

    live.py ghostty=<binary>|kgx <outdir> [--nolinks] [--perf]

Starts nothing Orca-related and never restarts Orca. It only watches:
dbus-monitor --profile on the real a11y bus, CPU ticks of the running Orca
and of the terminal, and optionally `perf record` of the terminal.

The terminal opens with "Press Enter to start". After Enter it writes 20,000
build-log lines at 4,000 lines/s, then the script waits for Orca to go idle,
records everything, and closes the window. Don't touch the keyboard until
then: flat review in particular makes Orca rebuild its review context on
every insertion, about twenty times the normal call rate, in any terminal.

Writes the same files analyze.py reads: marks.jsonl, bus.log, names.json,
and an empty speech.log (real speech isn't captured).
"""

import collections
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

terminal = sys.argv[1]
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
perf_on = "--perf" in sys.argv
here = Path(__file__).resolve().parent
procs = []
marks = open(out / "marks.jsonl", "w")
(out / "speech.log").write_text("")


def mark(kind, **kw):
    kw.update(kind=kind, t=time.time())
    marks.write(json.dumps(kw) + "\n")
    marks.flush()


def spawn(argv, log=None, env=None):
    p = subprocess.Popen(
        argv,
        stdout=open(log, "wb") if log else subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
        env=env or os.environ,
        start_new_session=True,
    )
    procs.append(p)
    return p


def cpu_ticks(pid):
    try:
        f = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return int(f[11]) + int(f[12])
    except (OSError, IndexError):
        return 0


def run(*argv):
    return subprocess.run(argv, capture_output=True, text=True).stdout.strip()


a11y = run("gdbus", "call", "--session", "--dest", "org.a11y.Bus", "--object-path",
           "/org/a11y/bus", "--method", "org.a11y.Bus.GetAddress")
a11y = a11y.removeprefix("('").removesuffix("',)")
orca_pids = run("pgrep", "-x", "orca").split()
assert len(orca_pids) == 1, f"expected exactly one running Orca, found {orca_pids}"
orca_pid = int(orca_pids[0])
print(f"a11y bus {a11y}, Orca pid {orca_pid}", flush=True)

spawn(["dbus-monitor", "--address", a11y, "--profile"], log=out / "bus.log")

start_file, done_file = out / "s", out / "d"
script = out / "flood.sh"
script.write_text(
    "printf 'Press Enter to start\\n'\n"
    "read -r _\n"
    "sleep 1\n"
    f"date +%s.%N > {start_file}\n"
    f"python3 -I {here}/pacer.py 20000 4000\n"
    f"date +%s.%N > {done_file}\n"
    "exec sleep 600\n"
)
env = dict(os.environ)
if terminal.startswith("ghostty"):
    binary = terminal.split("=", 1)[1]
    cfg = out / "config" / "ghostty"
    cfg.mkdir(parents=True, exist_ok=True)
    (cfg / "config").write_text(
        "gtk-single-instance = false\n"
        "window-width = 80\n"
        "window-height = 24\n"
        "shell-integration = none\n"
        "confirm-close-surface = false\n"
        "resize-overlay = never\n"
        "cursor-style-blink = false\n"
        + ("link-url = false\n" if "--nolinks" in sys.argv else "")
    )
    env["XDG_CONFIG_HOME"] = str(out / "config")
    term = spawn([binary, "-e", "sh", str(script)], log=out / "term.log", env=env)
elif terminal == "kgx":
    # A running kgx would take the window over into its own process; check
    # with `pgrep -x kgx` first.
    term = spawn(["kgx", "--", "sh", str(script)], log=out / "term.log", env=env)
else:
    raise SystemExit(f"unknown terminal {terminal}")
term_pids = [term.pid]


def cpu_snapshot(label):
    snap = {"orca": cpu_ticks(orca_pid), "registryd": 0,
            "term": sum(cpu_ticks(p) for p in term_pids)}
    threads = collections.Counter()
    for p in term_pids:
        for task in Path(f"/proc/{p}/task").glob("*"):
            try:
                comm = (task / "comm").read_text().strip()
            except OSError:
                continue
            threads[comm] += cpu_ticks(f"{p}/task/{task.name}")
    mark("cpu", label=label, threads=dict(threads), **snap)


def wait_orca_idle(quiet=2.0, limit=180.0):
    start = last_busy = time.time()
    prev = cpu_ticks(orca_pid)
    while time.time() - start < limit:
        time.sleep(0.05)
        cur = cpu_ticks(orca_pid)
        if cur != prev:
            last_busy, prev = time.time(), cur
        elif time.time() - last_busy >= quiet:
            return last_busy
    return None


def wait_file(f, limit):
    start = time.time()
    while time.time() - start < limit:
        if f.exists() and f.read_text().strip():
            return float(f.read_text().split()[0])
        time.sleep(0.02)
    return None


def bus_names():
    """Map every sender seen on the bus to its pid and command name."""
    senders = set()
    for line in (out / "bus.log").read_text(errors="replace").splitlines():
        f = line.split("\t")
        if len(f) > 3 and f[3].startswith(":"):
            senders.add(f[3])
    names = {}
    for s in sorted(senders):
        r = run("gdbus", "call", "--address", a11y, "--dest", "org.freedesktop.DBus",
                "--object-path", "/org/freedesktop/DBus", "--method",
                "org.freedesktop.DBus.GetConnectionUnixProcessID", s)
        try:
            pid = int(r.strip("(),").split()[-1])
            comm = Path(f"/proc/{pid}/comm").read_text().strip()
        except (ValueError, IndexError, OSError):
            continue
        # Other windows of the same terminal (the user's own Ghostty, say)
        # must not count as the terminal under test.
        if comm in ("ghostty", "kgx") and pid not in term_pids:
            comm += "-other"
        names[s] = {"pid": pid, "comm": comm}
    return names


try:
    print("Waiting for Enter in the new terminal window...", flush=True)
    wait_orca_idle(quiet=1.0, limit=30)
    sent = wait_file(start_file, limit=600)
    assert sent, "Enter was never pressed"
    # The start file is written a moment before the output starts, so the
    # CPU snapshot after it still precedes nearly all of the work.
    cpu_snapshot("flood_fast:start")
    mark("phase", name="flood_fast", state="start")
    mark("phase", name="flood_fast", state="cmd-sent")
    recorders = []
    if perf_on:
        recorders.append(spawn(
            ["perf", "record", "-q", "-e", "task-clock:u", "-F", "1999", "--call-graph", "fp",
             "--user-callchains", "-p", ",".join(map(str, term_pids)),
             "-o", str(out / "perf-flood_fast-term.data")],
            log=out / "perf-flood_fast-term.err"))
    done = wait_file(done_file, limit=120)
    mark("phase", name="flood_fast", state="producer-done", t_done=done)
    idle = wait_orca_idle(limit=600)
    mark("phase", name="flood_fast", state="end", orca_last_busy=idle)
    cpu_snapshot("flood_fast:end")
    for r in recorders:
        r.send_signal(signal.SIGINT)
        r.wait(timeout=60)
    names = bus_names()
    (out / "names.json").write_text(json.dumps(names, indent=1))
    mark("finished")
    print("done", flush=True)
finally:
    marks.close()
    for p in reversed(procs):
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
