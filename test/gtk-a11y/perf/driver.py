"""Drive one terminal + real Orca through typing and flood workloads.

Runs inside run.sh's private display / session bus / a11y bus.
Writes into <outdir>: marks.jsonl (driver timeline), bus.log (dbus-monitor
--profile of the a11y bus), speech.log (private speech-dispatcher sink),
orca.log (only with --orca-debug), names.json (bus name -> pid), probe.jsonl
(client-side reply latency), and with --perf, perf-<phase>-{term,orca}.data.
"""

import collections
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from Xlib import X, XK, display
from Xlib.ext import xtest

terminal = sys.argv[1]
out = Path(sys.argv[2]).resolve()
orca_debug = "--orca-debug" in sys.argv
only = [a.split("=", 1)[1] for a in sys.argv if a.startswith("--only=")]
# --perf: `perf record` the terminal and Orca during each flood phase, into
# perf-<phase>-{term,orca}.data. Orca runs with Python's perf trampolines so
# its Python frames get names.
perf_on = "--perf" in sys.argv
here = Path(__file__).resolve().parent
a11y = os.environ["A11Y_ADDR"]
procs = []
marks = open(out / "marks.jsonl", "w")


def mark(kind, **kw):
    kw.update(kind=kind, t=time.time())
    marks.write(json.dumps(kw) + "\n")
    marks.flush()


def spawn(argv, log=None, env=None, **kw):
    p = subprocess.Popen(
        argv,
        stdout=open(log, "wb") if log else subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
        env=env or os.environ,
        start_new_session=True,
        **kw,
    )
    procs.append(p)
    return p


def cleanup(*_):
    for p in reversed(procs):
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for p in procs:
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)


def cpu_ticks(pid):
    try:
        f = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return int(f[11]) + int(f[12])  # utime + stime, all threads
    except (OSError, IndexError):
        return 0


# -- private state ---------------------------------------------------------

home = out / "home"
for d in ("home", "config", "data", "cache", "state"):
    (out / d).mkdir(exist_ok=True)
base_env = dict(os.environ)
base_env.update(
    HOME=str(home),
    XDG_CONFIG_HOME=str(out / "config"),
    XDG_DATA_HOME=str(out / "data"),
    XDG_CACHE_HOME=str(out / "cache"),
    XDG_STATE_HOME=str(out / "state"),
)

# -- speech-dispatcher with a logging module --------------------------------

sd = out / "speechd"
(sd / "modules").mkdir(parents=True, exist_ok=True)
sock = Path(os.environ["XDG_RUNTIME_DIR"]) / "speechd.sock"
speech_log = out / "speech.log"
speech_log.touch()
(sd / "speechd.conf").write_text(
    f"""CommunicationMethod "unix_socket"
SocketPath "{sock}"
Timeout 0
LogLevel 2
LogDir "{sd}"
AudioOutputMethod "libao"
AddModule "logger" "sd_generic" "logger.conf"
DefaultModule logger
"""
)
(sd / "modules" / "logger.conf").write_text(
    f"""GenericExecuteSynth "printf '%s\\\\t%s\\\\n' \\"$(date +%s.%N)\\" \\'$DATA\\' >> {speech_log}"
AddVoice "en" "MALE1" "logger"
DefaultVoice "logger"
GenericLanguage "en" "en" "utf-8"
"""
)
spawn(
    ["speech-dispatcher", "-s", "-t", "0", "-C", str(sd), "-c", "unix_socket", "-S", str(sock)],
    log=out / "speechd.stdout",
    env=base_env,
)
for _ in range(100):
    if sock.exists():
        break
    time.sleep(0.05)
base_env["SPEECHD_ADDRESS"] = f"unix_socket:{sock}"

# -- fake Mutter keyboard monitor -------------------------------------------
#
# Orca's X11 key watcher selects XI key events on the root window, which GTK's
# own selection on its toplevel keeps from ever propagating there, so under
# Xvfb Orca hears no keys at all. On GNOME Wayland Orca instead gets keys from
# Mutter over D-Bus (org.freedesktop.a11y.KeyboardMonitor). Provide that, so
# key echo and typing work the way they do on a real desktop.

import threading  # noqa: E402

import gi  # noqa: E402

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

KBD_XML = """<node><interface name="org.freedesktop.a11y.KeyboardMonitor">
<method name="WatchKeyboard"/><method name="UnwatchKeyboard"/>
<method name="GrabKeyboard"/><method name="UngrabKeyboard"/>
<method name="SetKeyGrabs"><arg type="au" direction="in"/><arg type="a(uu)" direction="in"/></method>
<signal name="KeyEvent"><arg type="b"/><arg type="u"/><arg type="u"/><arg type="u"/><arg type="q"/></signal>
</interface></node>"""
KBD_PATH = "/org/freedesktop/a11y/Manager"
KBD_IFACE = "org.freedesktop.a11y.KeyboardMonitor"
session_bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
session_bus.register_object(
    KBD_PATH,
    Gio.DBusNodeInfo.new_for_xml(KBD_XML).interfaces[0],
    lambda conn, sender, path, iface, method, params, inv: inv.return_value(None),
    None,
    None,
)
session_bus.call_sync(
    "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
    GLib.Variant("(su)", ("org.freedesktop.a11y.Manager", 0)), None, Gio.DBusCallFlags.NONE, -1, None,
)
threading.Thread(target=GLib.MainLoop().run, daemon=True).start()


# GPU=1 runs under headless Mutter, which owns org.freedesktop.a11y.Manager
# itself, so the fake monitor above never gets the name. Keys go in through
# Mutter's RemoteDesktop instead: Mutter delivers them to the focused window
# and reports them to Orca through its own KeyboardMonitor, as on a real
# GNOME desktop.
gpu = bool(os.environ.get("GPU"))
rd_session = None
if gpu:
    rd_path = session_bus.call_sync(
        "org.gnome.Mutter.RemoteDesktop", "/org/gnome/Mutter/RemoteDesktop",
        "org.gnome.Mutter.RemoteDesktop", "CreateSession", None,
        GLib.VariantType("(o)"), Gio.DBusCallFlags.NONE, -1, None,
    ).unpack()[0]
    rd_session = Gio.DBusProxy.new_sync(
        session_bus, Gio.DBusProxyFlags.NONE, None, "org.gnome.Mutter.RemoteDesktop",
        rd_path, "org.gnome.Mutter.RemoteDesktop.Session", None,
    )
    rd_session.call_sync("Start", None, Gio.DBusCallFlags.NONE, -1, None)
    # The first key of a new virtual keyboard gets lost while Mutter sets up
    # its keymap; spend it on a bare Shift.
    for pressed in (True, False):
        rd_session.call_sync("NotifyKeyboardKeysym", GLib.Variant("(ub)", (0xFFE1, pressed)),
                             Gio.DBusCallFlags.NONE, -1, None)
        time.sleep(0.05)


def rd_key(keysym, pressed):
    rd_session.call_sync("NotifyKeyboardKeysym", GLib.Variant("(ub)", (keysym, pressed)),
                         Gio.DBusCallFlags.NONE, -1, None)


def emit_key(released, keysym, unichar, keycode):
    if gpu:
        return
    session_bus.emit_signal(
        None, KBD_PATH, KBD_IFACE, "KeyEvent",
        GLib.Variant("(buuuq)", (released, 0, keysym, unichar, keycode)),
    )
    session_bus.flush_sync(None)


base_env["ATSPI_USE_A11Y_MANAGER_DEVICE"] = "1"

# -- bus monitor -----------------------------------------------------------

spawn(["dbus-monitor", "--address", a11y, "--profile"], log=out / "bus.log")
if "--props" in sys.argv:
    # Full bodies, but only of PropertyChange: which property, and its value.
    spawn(["dbus-monitor", "--address", a11y, "type='signal',member='PropertyChange'"],
          log=out / "props.log")

# -- Orca ------------------------------------------------------------------

orca_argv = ["python3", str(here / "orca_launch.py")]
if orca_debug:
    orca_argv += ["--debug-file", str(out / "orca.log")]
if perf_on:
    # Writes /tmp/perf-<pid>.map, which names Python frames for perf report.
    orca_argv[1:1] = ["-X", "perf"]


def start_orca():
    p = spawn(orca_argv, log=out / "orca.stdout", env=base_env)
    time.sleep(5)
    return p


# Under Mutter (GPU=1) the window is focused the moment it maps. If Orca is
# already running it races the app's registration and is left treating
# kgx's terminal as dead, so Orca starts once the terminal is up and
# focused instead, and finds it at startup.
orca = None if gpu else start_orca()

# -- terminal --------------------------------------------------------------

done_file = out / "d"
# Short commands, typed relative to `out`: under Xvfb the setup typing is not
# routed to Orca as key events, so Orca reads every echoed chunk of it as
# output.
(out / "p1").write_text(f"exec python3 -I {here}/pacer.py 1500 200\n")
(out / "p2").write_text(f"exec python3 -I {here}/pacer.py 20000 4000\n")
shell = ["bash", "--norc", "--noprofile", "-i"]
term_env = dict(base_env)
term_env["PS1"] = "$ "
term_env["HISTFILE"] = "/dev/null"
if terminal.startswith("ghostty"):
    binary = terminal.split("=", 1)[1] if "=" in terminal else "/usr/bin/ghostty"
    cfg = out / "config" / "ghostty"
    cfg.mkdir(parents=True, exist_ok=True)
    (cfg / "config").write_text(
        """x11-instance-name = ghostty-perf
gtk-single-instance = false
gtk-titlebar = false
window-decoration = none
window-width = 80
window-height = 24
shell-integration = none
confirm-close-surface = false
resize-overlay = never
cursor-style-blink = false
"""
        + ("link-url = false\n" if "--nolinks" in sys.argv else "")
    )
    term = spawn([binary, "-e", *shell], log=out / "term.log", env=term_env)
elif terminal == "kgx":
    term = spawn(["kgx", "--", *shell], log=out / "term.log", env=term_env)
elif terminal == "ptyxis":
    term = spawn(["ptyxis", "-s", "--new-window", "--", *shell], log=out / "term.log", env=term_env)
else:
    raise SystemExit(f"unknown terminal {terminal}")

d = display.Display()


def xdotool(*args):
    return subprocess.run(["xdotool", *args], capture_output=True, text=True).stdout


win = None
for _ in range(200):
    ids = xdotool("search", "--onlyvisible", "--pid", str(term.pid)).split()
    if ids:
        win = ids[-1]
        break
    time.sleep(0.1)
assert win, "terminal window never appeared"


def focus(w):
    # Under a window manager (GPU=1, headless Mutter) a client's own
    # XSetInputFocus is overridden; ask the WM to activate the window instead.
    if gpu:
        xdotool("windowactivate", "--sync", str(w))
    else:
        xdotool("windowfocus", "--sync", str(w))


time.sleep(1.5)
focus(win)
time.sleep(2)
# The first window:activate races Orca's discovery of the new app and arrives
# for a DEAD object, leaving Orca on its default script. Bounce X focus through
# a throwaway window so a second activation lands on a known app.
screen = d.screen()
bounce = screen.root.create_window(0, 0, 10, 10, 0, screen.root_depth)
bounce.map()
d.sync()
time.sleep(0.3)
if gpu:
    focus(bounce.id)
else:
    bounce.set_input_focus(X.RevertToParent, X.CurrentTime)
    d.sync()
time.sleep(1)
focus(win)
time.sleep(2)
if orca is None:
    orca = start_orca()
    # Activate once more, now that Orca is listening, so it sees the
    # window activation and focus the way it would on a real desktop.
    focus(bounce.id)
    time.sleep(1)
    focus(win)
    time.sleep(2)
focused = xdotool("getwindowfocus").strip()
mark("focus", window=win, focused=focused)
print(f"window {win}, X focus on {focused}", flush=True)


def type_cmd(text):
    if gpu:
        for ch in text:
            press("space" if ch == " " else ch)
            time.sleep(0.008)
        press("Return")
        return
    xdotool("type", "--delay", "8", text)
    xdotool("key", "Return")


def combo(spec):
    """A key chord like "ctrl+u", as xdotool spells it."""
    if not gpu:
        xdotool("key", spec)
        return
    *mods, key = spec.split("+")
    held = [XK.string_to_keysym({"ctrl": "Control_L"}.get(m, m)) for m in mods]
    for k in held:
        rd_key(k, True)
    press(key)
    for k in reversed(held):
        rd_key(k, False)


def press(ch):
    keysym = XK.string_to_keysym(ch) if len(ch) > 1 else ord(ch)
    if gpu:
        t = time.time()
        rd_key(keysym, True)
        # Back-to-back press and release drop keys; xdotool also leaves a
        # gap between them.
        time.sleep(0.004)
        rd_key(keysym, False)
        time.sleep(0.004)
        return t
    code = d.keysym_to_keycode(keysym)
    uni = 32 if ch == "space" else (ord(ch) if len(ch) == 1 else 0)
    t = time.time()
    emit_key(False, keysym, uni, code)
    xtest.fake_input(d, X.KeyPress, code)
    d.sync()
    emit_key(True, keysym, uni, code)
    xtest.fake_input(d, X.KeyRelease, code)
    d.sync()
    return t


# Ask the shell how big the terminal is, and record bus name -> pid.
type_cmd(f"cd {out}; stty size > size; clear")
time.sleep(1)
names = {}
listing = subprocess.run(
    ["gdbus", "call", "--address", a11y, "--dest", "org.freedesktop.DBus",
     "--object-path", "/org/freedesktop/DBus", "--method", "org.freedesktop.DBus.ListNames"],
    capture_output=True, text=True,
).stdout
for name in listing.replace("[", " ").replace("]", " ").replace(",", " ").replace("'", " ").split():
    if not name.startswith(":"):
        continue
    r = subprocess.run(
        ["gdbus", "call", "--address", a11y, "--dest", "org.freedesktop.DBus",
         "--object-path", "/org/freedesktop/DBus",
         "--method", "org.freedesktop.DBus.GetConnectionUnixProcessID", name],
        capture_output=True, text=True,
    ).stdout
    digits = "".join(c for c in r if c.isdigit() or c == " ").split()
    if digits:
        pid = int(digits[-1])
        try:
            comm = Path(f"/proc/{pid}/comm").read_text().strip()
        except OSError:
            comm = "?"
        names[name] = {"pid": pid, "comm": comm}
(out / "names.json").write_text(json.dumps(names, indent=1))

# -- reply-latency probe ------------------------------------------------------
#
# How long the terminal takes to answer the synchronous Text calls Orca blocks
# on, timed client-side. dbus-monitor's timestamps can't tell us: it stamps
# messages when it reads them and reads in batches.

term_names = {n for n, v in names.items() if v["comm"] in ("ghostty", "kgx", "ptyxis")}
term_path = None
for line in (out / "bus.log").read_text(errors="replace").splitlines():
    f = line.split("\t")
    if len(f) > 7 and f[0] == "sig" and f[3] in term_names and f[7] == "TextChanged":
        term_name, term_path = f[3], f[5]
mark("probe-target", name=term_path and term_name, path=term_path)


def reply_probe():
    conn = Gio.DBusConnection.new_for_address_sync(
        a11y, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
        None, None,
    )
    log = open(out / "probe.jsonl", "w")
    calls = [("GetCharacterCount", None, "org.freedesktop.DBus.Properties", "Get"),
             ("GetText", GLib.Variant("(ii)", (0, -1)), "org.a11y.atspi.Text", "GetText")]
    i = 0
    while True:
        label, args, iface, member = calls[i % 2]
        if member == "Get":
            args = GLib.Variant("(ss)", ("org.a11y.atspi.Text", "CharacterCount"))
        t = time.time()
        try:
            conn.call_sync(term_name, term_path, iface, member, args, None, Gio.DBusCallFlags.NONE, 30000, None)
            ok = True
        except GLib.Error:
            ok = False
        log.write(json.dumps({"t": t, "call": label, "lat": time.time() - t, "ok": ok}) + "\n")
        log.flush()
        i += 1
        time.sleep(0.1)


if term_path:
    threading.Thread(target=reply_probe, daemon=True).start()
term_pids = {v["pid"] for v in names.values() if v["comm"] not in ("orca", "at-spi2-registr", "dbus-monitor", "python3", "gdbus")}
orca_pid = orca.pid
mark("setup", terminal=terminal, term_pids=sorted(term_pids), orca_pid=orca_pid, window=win)


def cpu_snapshot(label):
    snap = {"orca": cpu_ticks(orca_pid), "registryd": cpu_ticks(int(os.environ["REGISTRYD_PID"]))}
    snap["term"] = sum(cpu_ticks(p) for p in term_pids)
    threads = collections.Counter()
    for p in term_pids:
        for task in Path(f"/proc/{p}/task").glob("*"):
            try:
                comm = (task / "comm").read_text().strip()
            except OSError:
                continue
            threads[comm] += cpu_ticks(f"{p}/task/{task.name}")
    mark("cpu", label=label, threads=dict(threads), **snap)
    return snap


def wait_orca_idle(quiet=2.0, limit=180.0):
    """Wait until Orca burns no CPU for `quiet` seconds; return when it last did."""
    start = time.time()
    last_busy = time.time()
    prev = cpu_ticks(orca_pid)
    while time.time() - start < limit:
        time.sleep(0.05)
        cur = cpu_ticks(orca_pid)
        if cur != prev:
            last_busy = time.time()
            prev = cur
        elif time.time() - last_busy >= quiet:
            return last_busy
    return None


def wait_done(limit=300.0):
    start = time.time()
    while time.time() - start < limit:
        if done_file.exists() and done_file.read_text().strip():
            return float(done_file.read_text().split()[0])
        time.sleep(0.02)
    return None


TEXT = "the quick brown fox jumps over the lazy dog and keeps running "


def typing(name, cps, chars=TEXT * 2):
    wait_orca_idle()
    cpu_snapshot(f"{name}:start")
    mark("phase", name=name, state="start")
    gap = 1.0 / cps
    nxt = time.time()
    for ch in chars:
        nxt += gap
        t = press("space" if ch == " " else ch)
        mark("key", phase=name, ch=ch, t_press=t)
        delay = nxt - time.time()
        if delay > 0:
            time.sleep(delay)
    mark("phase", name=name, state="input-end")
    idle = wait_orca_idle()
    mark("phase", name=name, state="end", orca_last_busy=idle)
    cpu_snapshot(f"{name}:end")


def flood(name, cmd, probes_during=0.0):
    """Run `cmd`, optionally probing with a key every `probes_during` seconds while
    output is running, then probe once right after the producer exits."""
    wait_orca_idle()
    if done_file.exists():
        done_file.unlink()
    cpu_snapshot(f"{name}:start")
    recorders = []
    if perf_on:
        for who, pids in (("term", term_pids), ("orca", {orca_pid})):
            recorders.append(subprocess.Popen(
                # perf_event_paranoid=2 refuses kernel callchains, hence
                # task-clock:u and --user-callchains.
                ["perf", "record", "-q", "-e", "task-clock:u", "-F", "1999",
                 "--call-graph", "fp", "--user-callchains", "-p", ",".join(map(str, sorted(pids))),
                 "-o", str(out / f"perf-{name}-{who}.data")],
                stdout=subprocess.DEVNULL, stderr=open(out / f"perf-{name}-{who}.err", "wb"),
            ))
        time.sleep(0.5)
    mark("phase", name=name, state="start", cmd=cmd)
    type_cmd(f"{cmd};date +%s.%N>d")
    mark("phase", name=name, state="cmd-sent")
    if probes_during:
        probe_keys = "jkvpzbgh"
        i = 0
        while not (done_file.exists() and done_file.read_text().strip()):
            time.sleep(probes_during)
            if done_file.exists() and done_file.read_text().strip():
                break
            ch = probe_keys[i % len(probe_keys)]
            i += 1
            t = press(ch)
            mark("probe", phase=name, ch=ch, t_press=t, during=True)
    done = wait_done()
    mark("phase", name=name, state="producer-done", t_done=done)
    time.sleep(0.3)
    t = press("y")
    mark("probe", phase=name, ch="y", t_press=t, during=False)
    idle = wait_orca_idle(limit=600)
    mark("phase", name=name, state="end", orca_last_busy=idle)
    cpu_snapshot(f"{name}:end")
    for r in recorders:
        r.send_signal(signal.SIGINT)
    for r in recorders:
        r.wait(timeout=60)
    # Clear the probe characters off the prompt line.
    combo("ctrl+u")
    type_cmd("clear")
    time.sleep(1)


phases = {
    "type_cat_40cps": lambda: (type_cmd("cat"), time.sleep(1), typing("type_cat_40cps", 40),
                               combo("ctrl+c"), time.sleep(1)),
    "type_shell_15cps": lambda: (typing("type_shell_15cps", 15, TEXT), combo("ctrl+u"),
                                 time.sleep(1)),
    "flood_seq": lambda: flood("flood_seq", "seq 1 200000"),
    "flood_paced": lambda: flood("flood_paced", "sh p1", probes_during=0.5),
    "flood_fast": lambda: flood("flood_fast", "sh p2", probes_during=0.5),
    "flood_burst": lambda: flood("flood_burst", "ls -la /usr/lib|head -3000"),
}
try:
    for key, fn in phases.items():
        if only and key not in only:
            continue
        fn()
    mark("finished")
finally:
    marks.close()
    cleanup()
