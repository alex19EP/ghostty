"""Launch Ghostty under a private X/D-Bus session and talk to it over AT-SPI.

This is the plumbing shared by the `test_*.py` modules. It exists to make the
tests read like an assistive-technology client, because that is exactly what
they are: everything here goes through the same AT-SPI interfaces Orca uses,
so a regression that only an AT can see still fails a test.

Nothing in this file may be imported outside the harness — `run.sh` sets up
the display, the session bus and the accessibility bus before pytest starts.
"""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Iterator, Optional

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib  # noqa: E402

# Printed by the seed script as its first line. Tests wait until this shows up
# in the accessible text before asserting anything, which simultaneously proves
# the pty is live, a frame has rendered, and the AT-SPI plumbing works.
READY_MARKER = "GHOSTTY-A11Y-READY"

# WM_CLASS instance name / AT-SPI application name. On X11 Ghostty overrides
# `g_set_prgname` with `x11-instance-name` (winproto/x11.zig), and the AT-SPI
# bridge derives the application object's Name from prgname — so this string is
# what identifies us on the accessibility bus. See test_tree.py.
INSTANCE_NAME = "ghostty-a11y-test"

LINK_URI = "https://ghostty.org/docs"
LINK_LABEL = "Ghostty Docs"
BARE_URL = "https://example.com/bare"

# Seeded viewport. Deliberately mixed: ASCII, multi-byte text well past the
# BMP-vs-byte boundary, an OSC 8 hyperlink, and a bare URL for the configured
# regex matcher. `exec cat` at the end holds the pty open and echoes keystrokes,
# which is how the event tests type into a live terminal.
SEED_SCRIPT = f"""#!/bin/sh
printf '%s\\n' '{READY_MARKER}'
printf '%s\\n' 'alpha beta gamma'
printf '%s\\n' 'héllo wörld ✓ 日本語 end'
printf '\\033]8;;{LINK_URI}\\033\\\\{LINK_LABEL}\\033]8;;\\033\\\\ trailing\\n'
printf '%s\\n' 'visit {BARE_URL} now'
exec cat
"""

# Seed for test_click.py. Same shape, but the pty asks for mouse reporting:
# DECSET 1000 reports button press and release, DECSET 1006 encodes them as
# SGR — `ESC [ < button ; column ; row M` — which spells the coordinates out
# in decimal instead of packing them into bytes.
#
# Nothing here has to *read* those reports. The pty stays in canonical mode
# with ECHOCTL, so the tty driver echoes whatever Ghostty writes to it, and
# ESC echoes as `^[`. A click therefore lands in the viewport as literal text
# like `^[[<0;12;3M` — visible to the accessible-text API, and thus to a test.
MOUSE_SEED_SCRIPT = f"""#!/bin/sh
printf '%s\\n' '{READY_MARKER}'
printf '%s\\n' 'alpha beta gamma'
printf '%s\\n' 'delta epsilon zeta'
printf '%s\\n' 'wide 日本語 tail'
printf '\\033[?1000h\\033[?1006h'
exec cat
"""

# Seed for test_scroll.py. Prints more rows than the window is tall so there is
# real scrollback above the viewport, with every row distinct — identical rows
# would let a shift match at more than one offset and make the assertions
# ambiguous about which one the diff picked.
#
# The ready marker goes *last* here, unlike every other seed. Only the visible
# screen is exposed over AT-SPI, so a marker printed first would have scrolled
# out of the viewport by the time anything could look for it and `start()`
# would wait for it forever.
SCROLL_ROWS = 60
SCROLL_SEED_SCRIPT = f"""#!/bin/sh
i=0
while [ $i -lt {SCROLL_ROWS} ]; do
    printf 'row %03d filler\\n' "$i"
    i=$((i + 1))
done
printf '%s\\n' '{READY_MARKER}'
exec cat
"""

# Seed for test_burst.py. Waits for a line on stdin, then emits far more rows
# than the window is tall as fast as the pty will take them, and finishes with a
# marker and a bare prompt that has no trailing newline.
#
# The shape matters: two testers reported that after a burst of output the
# accessible text loses its tail — the last rows and the prompt are missing from
# Orca's flat review until the window is refocused. Reproducing that needs the
# burst to arrive *after* the terminal is already up and idle, which is what the
# `read` is for; a seed that prints at startup is a different case (the AT
# client attaches to a screen that is already final).
BURST_ROWS = 200
BURST_DONE = "BURST-DONE"
BURST_PROMPT = "$ "
BURST_ROW_FMT = "burst %03d filler"
BURST_SEED_SCRIPT = f"""#!/bin/sh
printf '%s\\n' '{READY_MARKER}'
while read _cmd; do
    i=0
    while [ $i -lt {BURST_ROWS} ]; do
        printf '{BURST_ROW_FMT}\\n' "$i"
        i=$((i + 1))
    done
    printf '%s\\n' '{BURST_DONE}'
    printf '%s' '{BURST_PROMPT}'
done
"""

# The same burst with nothing one byte wide in it.
#
# A third tester hit the missing-tail symptom under Nushell listing files with
# Czech names, and read it as a non-ASCII problem. The burst above cannot say
# whether he is right: it is pure ASCII, so for it a byte index, a codepoint
# index and a column are the same number, and every way we could confuse the
# three still produces the correct answer.
#
# So this seed makes them disagree, in the proportions his screen had. Box
# drawing is three bytes and one column, Czech is two bytes and one column, and
# the prompt ends in `〉` — Nushell's default indicator — which is three bytes
# and *two* columns. The prompt row is the row he said was missing, so it is
# the one that carries the wide character.
UNICODE_BURST_DONE = "BURST-DONE-ŽLUŤOUČKÝ"
UNICODE_BURST_PROMPT = "~/dokumenty/český〉"
UNICODE_BURST_ROW_FMT = "│ %03d │ příliš žluťoučký kůň úpěl ďábelské ódy │"
UNICODE_BURST_SEED_SCRIPT = f"""#!/bin/sh
printf '%s\\n' '{READY_MARKER}'
while read _cmd; do
    i=0
    while [ $i -lt {BURST_ROWS} ]; do
        printf '{UNICODE_BURST_ROW_FMT}\\n' "$i"
        i=$((i + 1))
    done
    printf '%s\\n' '{UNICODE_BURST_DONE}'
    printf '%s' '{UNICODE_BURST_PROMPT}'
done
"""


def burst_row(fmt: str, i: int) -> str:
    """The row `fmt` prints for index `i`, as it lands in the viewport.

    The seeds interpolate these formats into `sh`, so going through `%` here
    keeps a test's idea of a row and the script's from drifting apart.
    """
    return fmt % i

# Seed for test_title_label.py. The pty sets a recognisable window title before
# the ready marker, so the test can pick the header bar's title label out of
# the accessible tree by name, then on each Enter changes the title as fast as
# an agent's spinner would — an OSC 0 per millisecond — and restores the
# marker when it is done. `sleep 0.001` paces it so the storm lasts seconds
# rather than milliseconds; this is a race the test has to *sit inside*.
TITLE_MARKER = "GHOSTTY-TITLE-MARKER"
TITLE_SPINS = 3000
TITLE_SPIN_DONE = "TITLE-SPIN-DONE"
TITLE_SEED_SCRIPT = f"""#!/bin/sh
printf '\\033]0;{TITLE_MARKER}\\007'
printf '%s\\n' '{READY_MARKER}'
while read _cmd; do
    i=0
    while [ $i -lt {TITLE_SPINS} ]; do
        printf '\\033]0;spin %d\\007' "$i"
        sleep 0.001
        i=$((i + 1))
    done
    printf '\\033]0;{TITLE_MARKER}\\007'
    printf '%s\\n' '{TITLE_SPIN_DONE}'
done
"""

CONFIG_TEMPLATE = """
x11-instance-name = {instance}
gtk-single-instance = false
gtk-titlebar = false
window-decoration = none
window-width = 100
window-height = 30
window-padding-x = 0
window-padding-y = 0
shell-integration = none
confirm-close-surface = false
resize-overlay = never
cursor-style-blink = false
link-url = true

# One-line scroll, for test_scroll.py. Ghostty binds no single key to this by
# default and the default page-sized bindings replace the whole viewport, which
# is precisely the case a shift diff cannot help with — a partial scroll is what
# exercises it. F9/F10 are unbound both here and in the pty behind the tests.
keybind = f9=scroll_page_lines:-1
keybind = f10=scroll_page_lines:1

# Keyboard selection, for test_keyboard_selection.py. Ghostty ships no default
# binding for `start_selection` — the shift+arrow binds that *extend* a
# selection are defaults and need no help here, which is the whole point of the
# action. F8 is unbound both here and in the pty behind the tests.
keybind = f8=start_selection

# Caret mode, for test_caret_mode.py. `enter_caret_mode` has no default
# binding either; once inside, the built-in "caret" key table supplies the
# movement keys, so F7 is the only one the harness has to provide.
keybind = f7=enter_caret_mode

# Link activation, for test_link_activation.py. Marked `performable` so the
# binding reports whether it found a link: on a hit it is consumed and nothing
# reaches the pty, on a miss it falls through and `cat` echoes F6's escape
# sequence into the viewport. That echo is the only way a test can observe
# link *detection* without actually launching a browser.
keybind = performable:f6=open_link
"""


# X11 window ids already handed to a Session. Sessions are indistinguishable
# by class name, so this is what stops a second one from claiming the first
# one's window. See `Session.focus`.
_CLAIMED_WINDOWS: set[str] = set()


class Timeout(Exception):
    """A wait helper gave up. Always raised with what it was waiting for."""


def _wait(what: str, predicate, timeout: float = 20.0, interval: float = 0.05):
    """Poll `predicate` until it returns something truthy, then return it."""
    deadline = time.monotonic() + timeout
    last_error: Optional[Exception] = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except GLib.Error as err:
            # The app is still coming up, or an object went away mid-walk.
            # Either way it is worth retrying; remember it for the message.
            last_error = err
        time.sleep(interval)
    suffix = f" (last error: {last_error})" if last_error else ""
    raise Timeout(f"timed out after {timeout}s waiting for {what}{suffix}")


def ghostty_binary() -> Path:
    """Resolve the Ghostty under test. `run.sh` normally sets GHOSTTY_BIN."""
    env = os.environ.get("GHOSTTY_BIN")
    if env:
        return Path(env)
    root = Path(__file__).resolve().parents[2]
    return root / "zig-out" / "bin" / "ghostty"


class Session:
    """A running Ghostty plus the AT-SPI objects that describe it."""

    def __init__(
        self,
        seed: str = SEED_SCRIPT,
        instance: str = INSTANCE_NAME,
        env: Optional[dict] = None,
        config: str = "",
    ) -> None:
        self.seed_script = seed
        # Both the AT-SPI application name and the WM_CLASS instance name, so
        # a module running two Ghosttys at once can tell them apart. Sharing
        # one name makes the second session find the first one's application
        # object and wait for a ready marker that has long scrolled away.
        self.instance = instance
        self.extra_env = dict(env or {})
        # Appended after CONFIG_TEMPLATE; a later scalar key wins, so this is
        # how a module opts back into something the template turns off (the
        # header bar, for test_title_label.py).
        self.extra_config = config
        self.tmpdir = Path(tempfile.mkdtemp(prefix="ghostty-a11y-"))
        self.proc: Optional[subprocess.Popen] = None
        self._app: Optional[Atspi.Accessible] = None
        self._terminal: Optional[Atspi.Accessible] = None
        self._window_id: Optional[str] = None

    # -- lifecycle ----------------------------------------------------

    def start(self) -> "Session":
        binary = ghostty_binary()
        if not binary.exists():
            raise FileNotFoundError(
                f"{binary} not found — build it first, see test/gtk-a11y/README.md"
            )

        config_dir = self.tmpdir / "config" / "ghostty"
        config_dir.mkdir(parents=True)
        (config_dir / "config").write_text(
            CONFIG_TEMPLATE.format(instance=self.instance) + self.extra_config
        )

        seed = self.tmpdir / "seed.sh"
        seed.write_text(self.seed_script)
        seed.chmod(0o755)

        env = dict(os.environ)
        env.update(
            {
                # Isolate every scrap of state this run could touch.
                "XDG_CONFIG_HOME": str(self.tmpdir / "config"),
                "XDG_DATA_HOME": str(self.tmpdir / "data"),
                "XDG_CACHE_HOME": str(self.tmpdir / "cache"),
                "XDG_STATE_HOME": str(self.tmpdir / "state"),
                "HOME": str(self.tmpdir / "home"),
                # Force the a11y backend on; without it there is nothing to test.
                "GTK_A11Y": "atspi",
                # Xvfb has no hardware GL and the GLArea must produce frames:
                # `axNotifyIfChanged` hangs off the render callback.
                "LIBGL_ALWAYS_SOFTWARE": "1",
                "GDK_BACKEND": "x11",
            }
        )
        env.update(self.extra_env)
        for key in ("data", "cache", "state", "home"):
            (self.tmpdir / key).mkdir(exist_ok=True)

        log = open(self.tmpdir / "ghostty.log", "wb")
        self._log_path = self.tmpdir / "ghostty.log"
        self.proc = subprocess.Popen(
            [str(binary), "-e", "/bin/sh", str(seed)],
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )

        try:
            self._app = _wait(
                f"application {self.instance!r} on the accessibility bus",
                self._find_app,
            )
            self._terminal = _wait(
                "an accessible with role TERMINAL",
                lambda: find_role(self._app, Atspi.Role.TERMINAL),
            )
            _wait(
                f"{READY_MARKER!r} in the accessible text",
                lambda: READY_MARKER in self.text(),
            )
            self.focus()
        except Exception:
            self.stop()
            raise
        return self

    def stop(self) -> None:
        if self._window_id is not None:
            _CLAIMED_WINDOWS.discard(self._window_id)
            self._window_id = None
        if self.proc is not None and self.proc.poll() is None:
            # The whole app lives in its own process group (start_new_session),
            # so this also reaps the shell and `cat` behind the pty.
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
                self.proc.wait(timeout=5)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            self.proc = None
        if os.environ.get("GHOSTTY_A11Y_KEEP"):
            print(f"\nleaving {self.tmpdir} in place (GHOSTTY_A11Y_KEEP)")
        else:
            shutil.rmtree(self.tmpdir, ignore_errors=True)

    def diagnostics(self) -> str:
        """Ghostty's own stderr, for when a wait times out."""
        try:
            return self._log_path.read_text(errors="replace")
        except OSError:
            return "<no log>"

    # -- accessible lookup --------------------------------------------

    def _find_app(self) -> Optional[Atspi.Accessible]:
        desktop = Atspi.get_desktop(0)
        for i in range(desktop.get_child_count()):
            child = desktop.get_child_at_index(i)
            if child is not None and child.get_name() == self.instance:
                return child
        return None

    @property
    def app(self) -> Atspi.Accessible:
        assert self._app is not None, "session not started"
        return self._app

    @property
    def terminal(self) -> Atspi.Accessible:
        assert self._terminal is not None, "session not started"
        return self._terminal

    @property
    def frame(self) -> Atspi.Accessible:
        """The toplevel window. Orca's `frame_and_dialog` lookup needs its role.

        The topmost node is the *application* object, which sits between the
        toplevel and the desktop — so stop one below it rather than walking
        all the way up.
        """
        node = self.terminal
        while node is not None:
            parent = node.get_parent()
            if parent is None or parent.get_role() in (
                Atspi.Role.APPLICATION,
                Atspi.Role.DESKTOP_FRAME,
            ):
                return node
            node = parent
        raise AssertionError("no toplevel above the terminal")

    # -- text ----------------------------------------------------------

    def text(self) -> str:
        """The full accessible text.

        Python strings are codepoint-indexed and so are AT-SPI offsets, so
        indices into this string are directly usable as AT-SPI offsets. That
        equivalence is the whole point — see test_text.py.
        """
        return Atspi.Text.get_text(self.terminal, 0, -1)

    def offset_of(self, needle: str) -> int:
        text = self.text()
        index = text.index(needle)
        return index

    def row_of(self, needle: str) -> int:
        """Index of the viewport row containing `needle`."""
        text = self.text()
        return text[: text.index(needle)].count("\n")

    def wait_for_text(self, predicate, what: str, timeout: float = 10.0) -> str:
        return _wait(what, lambda: predicate(self.text()) and self.text(), timeout)

    # -- input ---------------------------------------------------------

    # -- geometry ------------------------------------------------------

    def range_extents(self, start: int, end: int):
        """The rect covering a codepoint range, in window coordinates."""
        return Atspi.Text.get_range_extents(
            self.terminal, start, end, Atspi.CoordType.WINDOW
        )

    def extents(self):
        """The terminal widget's own rect, in window coordinates.

        GTK derives this from the widget's allocation instead of asking us for
        it, which is what makes it an independent check on the rects we do
        compute — and it is the box Orca intersects flat-review zones with.
        """
        return Atspi.Component.get_extents(self.terminal, Atspi.CoordType.WINDOW)

    def offset_at_point(self, x: int, y: int) -> int:
        """The codepoint offset at a window-coordinate point."""
        return Atspi.Text.get_offset_at_point(
            self.terminal, x, y, Atspi.CoordType.WINDOW
        )

    # -- input ----------------------------------------------------------

    def focus(self) -> None:
        """Give the toplevel X input focus.

        Required for input, not cosmetic: `type_text` and `send_key` go
        through XTEST, which delivers to whichever window holds focus. There
        is no window manager under Xvfb, hence the explicit XSetInputFocus.

        Change events no longer depend on this — `glareaRender` dropped its
        focus gate — so a test that only reads or only listens does not need
        to call it. See test_focus.py.

        Sessions that share an instance name are indistinguishable to the
        xdotool search, so resolve the window once and remember it: without
        that, calling `focus()` on the first session after a second one has
        started hands focus to the *second* window and silently tests the
        wrong terminal.
        """
        if self._window_id is None:
            window = _wait(
                "the X11 window to map",
                lambda: [
                    w
                    for w in subprocess.run(
                        ["xdotool", "search", "--onlyvisible", "--classname",
                         self.instance],
                        capture_output=True,
                        text=True,
                    ).stdout.split()
                    if w not in _CLAIMED_WINDOWS
                ],
            )
            self._window_id = window[-1]
            _CLAIMED_WINDOWS.add(self._window_id)
        subprocess.run(["xdotool", "windowraise", self._window_id], check=False)
        subprocess.run(["xdotool", "windowfocus", self._window_id], check=True)

    def prime_change_events(self) -> None:
        """Force one change-notify cycle, so later diffs are steady-state.

        The first change an AT client observes after attaching has no previous
        snapshot to diff against, so it is announced as one insert covering the
        whole viewport. That is correct — the client has to learn the text
        somehow — but it is not the incremental behaviour the event tests are
        about, and it would otherwise land on whichever test happened to run
        first.
        """
        with Events("object:text-changed") as events:
            self.type_text(".")
            events.pump(2.0)

    def type_text(self, text: str) -> None:
        """Type into the terminal via XTEST, i.e. as a real keyboard would."""
        assert self._window_id is not None, "focus() first"
        subprocess.run(
            ["xdotool", "type", "--clearmodifiers", "--delay", "20", text],
            check=True,
        )

    def send_key(self, key: str) -> None:
        assert self._window_id is not None, "focus() first"
        subprocess.run(["xdotool", "key", "--clearmodifiers", key], check=True)


def as_hyperlink(link) -> Atspi.Hyperlink:
    """Normalise whatever `Atspi.Hypertext.get_link` handed back.

    at-spi2's client library keys accessibles and hyperlinks in a single
    per-application hash, so a hyperlink whose D-Bus path is already in the
    accessible cache comes back typed as `Atspi.Accessible` — even though the
    object does implement the Hyperlink interface. Ghostty parents its
    hyperlinks (it must; an unrealized AT context crashes the bridge), which
    puts them in that cache, so this is the shape a real client sees.

    Orca handles both shapes the same way, in `AXHypertext.get_link_uri` and
    friends: use the object directly if it is a Hyperlink, otherwise ask the
    accessible for its hyperlink. Mirroring that here keeps the tests honest
    about what the actual consumer does.
    """
    if isinstance(link, Atspi.Hyperlink):
        return link
    return Atspi.Accessible.get_hyperlink(link)


def find_role(root: Atspi.Accessible, role: Atspi.Role) -> Optional[Atspi.Accessible]:
    """Depth-first search for the first descendant (or self) with `role`."""
    for node in walk(root):
        if node.get_role() == role:
            return node
    return None


def walk(root: Atspi.Accessible) -> Iterator[Atspi.Accessible]:
    """Yield `root` and every descendant, depth-first."""
    stack = [root]
    while stack:
        node = stack.pop()
        yield node
        try:
            count = node.get_child_count()
        except GLib.Error:
            continue
        for i in reversed(range(count)):
            child = node.get_child_at_index(i)
            if child is not None:
                stack.append(child)


class Events:
    """Collect AT-SPI events, the way a screen reader receives them.

    Used as a context manager so registration is always torn down::

        with Events("object:text-changed") as events:
            session.type_text("x")
            events.pump(1.0)
        assert len(events.inserts()) == 1
    """

    def __init__(self, *types: str) -> None:
        self.types = types
        self.records: list[dict] = []
        self._listener = Atspi.EventListener.new(self._on_event)

    def __enter__(self) -> "Events":
        for type_ in self.types:
            self._listener.register(type_)
        # Drain anything already queued so the caller starts from a clean slate.
        self.pump(0.2)
        self.records.clear()
        return self

    def __exit__(self, *_exc) -> None:
        for type_ in self.types:
            self._listener.deregister(type_)

    def _on_event(self, event) -> None:
        # Copy everything out: the Atspi.Event is freed once we return.
        # PyGObject already unwraps `any_data` from its GValue, so it arrives
        # as a plain str for text-changed and as other types elsewhere.
        data = event.any_data if isinstance(event.any_data, str) else None
        self.records.append(
            {
                "type": event.type,
                "detail1": event.detail1,
                "detail2": event.detail2,
                "data": data,
            }
        )

    def pump(self, seconds: float) -> None:
        """Run the GLib main loop so queued events get delivered."""
        GLib.timeout_add(int(seconds * 1000), self._quit)
        Atspi.event_main()

    @staticmethod
    def _quit() -> bool:
        Atspi.event_quit()
        return False  # one-shot

    def of_type(self, suffix: str) -> list[dict]:
        return [r for r in self.records if r["type"].endswith(suffix)]

    def inserts(self) -> list[dict]:
        return self.of_type("insert")

    def deletes(self) -> list[dict]:
        return self.of_type("delete")

    def summary(self) -> str:
        """Human-readable dump, used in assertion messages."""
        if not self.records:
            return "<no events>"
        return "\n".join(
            f"  {r['type']} detail1={r['detail1']} detail2={r['detail2']} "
            f"data={r['data']!r}"
            for r in self.records
        )
