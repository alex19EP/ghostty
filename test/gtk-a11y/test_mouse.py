"""Real pointer input, after focus moved off the render surface.

Focus and key handling used to live on the render surface. They now live on
GhosttySurface, so the focused object is the one that carries role=terminal
and GtkAccessibleText. The pointer controllers stayed where they were, on the
box around the render surface, and the render surface itself is now
`accessible-role: presentation` and no longer focusable.

None of that is visible to a screen reader user, which is exactly why it gets
its own module: every test here drives the pointer through XTEST, the way a
sighted user's mouse would, and checks the outcome a sighted user would see.
test_click.py covers the *synthetic* click behind braille cursor routing; this
covers the real one.

Two observations do the work. The pty echoes everything Ghostty writes to it
(ECHOCTL turns ESC into `^[`), so mouse reports, focus reports and pastes all
land in the viewport as text. And `cat` echoes typed keys, so "typing reaches
the terminal" is "the typed marker shows up in the accessible text".
"""

from __future__ import annotations

import re
import subprocess
import time

import gi
import pytest

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

import harness  # noqa: E402
from test_click import LEFT, cell_of, reports  # noqa: E402

# SGR button codes, as in test_click.py.
MIDDLE = 1
RIGHT = 2
WHEEL_UP = 64
WHEEL_DOWN = 65

# Focus reports (DECSET 1004) after the tty echoed them.
FOCUS = re.compile(r"\^\[\[([IO])")

# Mouse reporting plus focus reporting, for the tests that read what the
# program behind the pty receives.
REPORTING_SEED = f"""#!/bin/sh
printf '%s\\n' '{harness.READY_MARKER}'
printf '%s\\n' 'alpha beta gamma'
printf '%s\\n' 'delta epsilon zeta'
printf '\\033[?1000h\\033[?1006h\\033[?1004h'
exec cat
"""

# No mouse reporting, so the pointer drives Ghostty's own selection, paste and
# context menu. Focus reporting stays on: it is how a test sees focus move.
PLAIN_SEED = f"""#!/bin/sh
printf '%s\\n' '{harness.READY_MARKER}'
printf '%s\\n' 'alpha beta gamma'
printf '%s\\n' 'delta epsilon zeta'
printf '\\033[?1004h'
exec cat
"""

# F2, F3 and F4 are unbound in the template and in the pty.
EXTRA_CONFIG = """
keybind = f2=new_split:down
keybind = f3=start_search
keybind = f4=new_split:right
"""


def xdotool(*args: str) -> str:
    return subprocess.run(
        ["xdotool", *args], check=True, capture_output=True, text=True
    ).stdout


def window_origin(session) -> tuple[int, int, int, int]:
    """The window's screen rect, from X rather than from AT-SPI."""
    geometry = dict(
        line.split("=", 1)
        for line in xdotool("getwindowgeometry", "--shell", session._window_id).split()
    )
    return (
        int(geometry["X"]),
        int(geometry["Y"]),
        int(geometry["WIDTH"]),
        int(geometry["HEIGHT"]),
    )


def cell_rect(session, needle: str, index: int = 0) -> tuple[int, int, int, int]:
    """Screen rect of codepoint `index` of `needle`.

    Comes from the accessible text extents, which is fine here: with a single
    surface they are known to be right (test_scaling.py), and the tests that
    care about the exact cell check it against what the pty reports.
    """
    offset = session.offset_of(needle) + index
    rect = session.range_extents(offset, offset + 1)
    x, y, _, _ = window_origin(session)
    return x + rect.x, y + rect.y, rect.width, rect.height


def point_in(session, needle: str, index: int = 0, fx: float = 0.5) -> tuple[int, int]:
    x, y, w, h = cell_rect(session, needle, index)
    return x + int(w * fx), y + h // 2


def move(x: int, y: int) -> None:
    xdotool("mousemove", "--sync", str(x), str(y))


def click(x: int, y: int, button: int = 1, repeat: int = 1) -> None:
    move(x, y)
    xdotool("click", "--repeat", str(repeat), "--delay", "60", str(button))


def focus_reports(text: str) -> list[str]:
    return FOCUS.findall(text)


def typed_reaches_terminal(session, marker: str) -> bool:
    session.type_text(marker)
    try:
        session.wait_for_text(lambda t: marker in t, f"{marker!r} echoed", timeout=3)
    except harness.Timeout:
        return False
    return True


def new_line(session) -> None:
    """Finish the current `cat` line so the next test starts on a clean one."""
    session.send_key("Return")
    time.sleep(0.2)


# -- what the program behind the pty receives -------------------------------


@pytest.fixture(scope="module")
def reporting(launch):
    return launch(REPORTING_SEED, instance="ghostty-mouse-reporting", config=EXTRA_CONFIG)


@pytest.mark.parametrize("button,code", [(1, LEFT), (2, MIDDLE), (3, RIGHT)])
def test_a_click_is_reported_at_the_cell_under_the_pointer(reporting, button, code):
    """The pointer controllers still see clicks on the presentation-role surface."""
    row, col = cell_of(reporting.text(), "epsilon")
    seen = len(reports(reporting.text()))

    click(*point_in(reporting, "epsilon"), button=button)

    text = reporting.wait_for_text(
        lambda t: len(reports(t)) >= seen + 2, "a press and a release"
    )
    assert reports(text)[seen:seen + 2] == [
        (code, col + 1, row + 1, "M"),
        (code, col + 1, row + 1, "m"),
    ]
    new_line(reporting)


def test_the_wheel_is_reported(reporting):
    seen = len(reports(reporting.text()))

    click(*point_in(reporting, "alpha"), button=4)
    click(*point_in(reporting, "alpha"), button=5)

    # One notch can be more than one report, so compare the order of the
    # distinct buttons rather than a count.
    text = reporting.wait_for_text(
        lambda t: WHEEL_DOWN in [r[0] for r in reports(t)[seen:]], "a wheel-down report"
    )
    buttons = [r[0] for r in reports(text)[seen:]]
    assert list(dict.fromkeys(buttons)) == [WHEEL_UP, WHEEL_DOWN], buttons
    new_line(reporting)


def test_clicking_back_from_search_restores_focus_and_keys(reporting):
    """Search takes focus; a click on the terminal must give it back.

    `gcMouseDown` grabs focus when the surface does not have it. It used to
    ask the render surface, and now asks GhosttySurface; with search open the
    search entry is focused, which is *inside* GhosttySurface, so this is the
    case where asking the wrong widget would leave the keyboard in the entry.
    """
    before = len(focus_reports(reporting.text()))
    reporting.send_key("F3")
    reporting.wait_for_text(
        lambda t: focus_reports(t)[before:] == ["O"], "a focus-out as search opens"
    )
    assert not typed_reaches_terminal(reporting, "insearch"), (
        "keys typed into search reached the pty"
    )

    click(*point_in(reporting, "gamma"))

    reporting.wait_for_text(
        lambda t: focus_reports(t)[before:][-1:] == ["I"], "a focus-in after the click"
    )
    assert typed_reaches_terminal(reporting, "backfromsearch")
    reporting.send_key("Escape")
    new_line(reporting)


# -- Ghostty's own pointer features -----------------------------------------


@pytest.fixture(scope="module")
def plain(launch):
    return launch(PLAIN_SEED, instance="ghostty-mouse-plain", config=EXTRA_CONFIG)


def paste_primary(session, marker: str) -> str:
    """Type `marker`, middle-click to paste PRIMARY after it, return the line."""
    session.focus()
    session.type_text(marker)
    session.wait_for_text(lambda t: marker in t, f"{marker!r} echoed")
    click(*point_in(session, "zeta"), button=2)
    text = session.wait_for_text(
        lambda t: re.search(re.escape(marker) + r"\S+", t), "a paste after the marker"
    )
    pasted = re.search(re.escape(marker) + r"(\S+)", text).group(1)
    new_line(session)
    return pasted


def test_dragging_selects_and_middle_click_pastes_it(plain):
    start = point_in(plain, "epsilon", 0, fx=0.2)
    end = point_in(plain, "epsilon", len("epsilon") - 1, fx=0.8)

    move(*start)
    xdotool("mousedown", "1")
    move((start[0] + end[0]) // 2, start[1])
    move(*end)
    xdotool("mouseup", "1")

    assert paste_primary(plain, "drag:") == "epsilon"


def test_double_click_selects_a_word(plain):
    click(*point_in(plain, "gamma", 2), repeat=2)

    assert paste_primary(plain, "word:") == "gamma"


def test_context_menu_returns_focus_to_the_terminal(plain):
    """The popover takes focus while open and must hand it back on close."""
    plain.focus()
    before = len(focus_reports(plain.text()))

    click(*point_in(plain, "beta"), button=3)
    plain.wait_for_text(
        lambda t: "O" in focus_reports(t)[before:], "a focus-out as the menu opens"
    )
    plain.send_key("Escape")

    plain.wait_for_text(
        lambda t: focus_reports(t)[before:][-1:] == ["I"], "a focus-in as it closes"
    )
    assert typed_reaches_terminal(plain, "aftermenu")
    new_line(plain)


# -- splits -----------------------------------------------------------------


def terminals(session) -> list[Atspi.Accessible]:
    return [
        node
        for node in harness.walk(session.app)
        if node.get_role() == Atspi.Role.TERMINAL
    ]


def split(launch, instance: str, key: str, config: str = ""):
    # `-e` only sets the first surface's command; a new split runs `command`,
    # which would otherwise be the user's shell in an empty HOME. It turns on
    # mouse reporting like the first one, so routing in either can be read
    # back; the escape bytes come in through the environment.
    session = launch(
        REPORTING_SEED,
        instance=instance,
        env={"GHOSTTY_TEST_MOUSE_ON": "\033[?1000h\033[?1006h"},
        config=EXTRA_CONFIG
        + "command = /bin/sh -c 'echo second-split; printf \"$GHOSTTY_TEST_MOUSE_ON\"; exec cat'\n"
        + config,
    )
    session.send_key(key)
    harness._wait("a second terminal", lambda: len(terminals(session)) == 2)
    # Let the new split map and start `cat`.
    time.sleep(1.0)
    session.direction = "right" if key == "F4" else "down"
    return session


def halves(session) -> tuple[tuple[int, int], tuple[int, int]]:
    """A point in the first and in the second split, from X geometry alone."""
    x, y, w, h = window_origin(session)
    if session.direction == "right":
        return (x + w // 4, y + h // 2), (x + 3 * w // 4, y + h // 2)
    return (x + w // 2, y + h // 4), (x + w // 2, y + 3 * h // 4)


def wait_focus_moves(session, before: list[int]) -> int:
    """Wait for AT-SPI focus to settle on one split other than `before`.

    Typing straight after the pointer moves races GTK's handling of the
    motion: half the marker lands in each split and neither holds all of it.
    """
    now = harness._wait(
        "focus to move to another split",
        lambda: (f := focused(session)) and len(f) == 1 and f != before and f,
        timeout=5,
    )
    return now[0]


def which_got(session, marker: str) -> int:
    session.type_text(marker)
    found = harness._wait(
        f"{marker!r} in some split",
        lambda: [
            i
            for i, t in enumerate(terminals(session))
            if marker in Atspi.Text.get_text(t, 0, -1)
        ],
        timeout=5,
    )
    assert len(found) == 1, f"{marker!r} appeared in splits {found}"
    return found[0]


def focused(session) -> list[int]:
    return [
        i
        for i, t in enumerate(terminals(session))
        if t.get_state_set().contains(Atspi.StateType.FOCUSED)
    ]


@pytest.fixture(scope="module", params=["F4", "F2"], ids=["right", "down"])
def splits(launch, request):
    return split(launch, f"ghostty-mouse-splits-{request.param}", request.param)


def test_clicking_a_split_moves_keys_and_focus_there(splits):
    first, second = halves(splits)
    splits.focus()

    # The new split took focus, so a click on the first one must move it.
    before = focused(splits)
    click(*first)
    got_first = wait_focus_moves(splits, before)
    assert which_got(splits, f"click1{splits.direction}") == got_first, (
        "AT-SPI focus disagrees with where keys went"
    )

    click(*second)
    got_second = wait_focus_moves(splits, [got_first])
    assert which_got(splits, f"click2{splits.direction}") == got_second, (
        "AT-SPI focus disagrees with where keys went"
    )
    new_line(splits)


def test_split_extents_have_distinct_origins(splits):
    """The GTK bridge bug: every split reported at the window origin.

    Measured with two tmux panes stacked top to bottom on GTK 4.22
    (2026-09-02). Kept as a test so the next GTK either way is visible.
    """
    rects = [
        Atspi.Component.get_extents(t, Atspi.CoordType.WINDOW) for t in terminals(splits)
    ]
    for i, r in enumerate(rects):
        print(f"  {splits.direction} split {i}: x={r.x} y={r.y} w={r.width} h={r.height}")
    assert len({(r.x, r.y) for r in rects}) == 2, "all splits report the same origin"


def test_split_text_extents_are_inside_their_split(splits):
    """What flat review and braille routing actually use: per-character rects.

    `get_range_extents` goes through our own `get_extents` vfunc, which is
    widget-local, and GTK adds the widget's position. If GTK places every
    split at the origin, the second split's text claims to sit in the first.
    """
    for i, t in enumerate(terminals(splits)):
        box = Atspi.Component.get_extents(t, Atspi.CoordType.WINDOW)
        text = Atspi.Text.get_text(t, 0, -1)
        rect = Atspi.Text.get_range_extents(t, 0, 1, Atspi.CoordType.WINDOW)
        print(f"  {splits.direction} split {i}: first char at x={rect.x} y={rect.y}"
              f" in box x={box.x} y={box.y} ({len(text)} chars)")
        assert box.x <= rect.x < box.x + box.width
        assert box.y <= rect.y < box.y + box.height


def test_split_extents_in_screen_coordinates(splits):
    """Not a requirement, a record: GTK has no screen coordinates.

    `gtk_at_spi_translate_coordinates_from_accessible` answers SCREEN with
    (0, 0) for every widget and keeps the width and height, and the Text
    extents methods refuse SCREEN outright. That is what "every split at the
    window origin" was. Orca asks for WINDOW everywhere.
    """
    for i, t in enumerate(terminals(splits)):
        r = Atspi.Component.get_extents(t, Atspi.CoordType.SCREEN)
        print(f"  {splits.direction} split {i} SCREEN: x={r.x} y={r.y} w={r.width} h={r.height}")


def test_braille_routing_clicks_inside_each_split(splits):
    """Routing is our own grid math, so the split's position must not matter.

    The click goes through `synthesizeClick` in widget-local coordinates; the
    report comes back from whichever split's pty received it.
    """
    for i, t in enumerate(terminals(splits)):
        text = Atspi.Text.get_text(t, 0, -1)
        # Neither target is in column 1, where a lost offset would land too.
        needle = "epsilon" if "epsilon" in text else "split"
        row, col = cell_of(text, needle)
        seen = len(reports(text))

        assert Atspi.Text.set_caret_offset(t, text.index(needle))
        got = harness._wait(
            f"a report from split {i}",
            lambda: (r := reports(Atspi.Text.get_text(t, 0, -1))[seen:]) and r,
            timeout=5,
        )
        print(f"  {splits.direction} split {i}: routed to {needle!r} at"
              f" ({col + 1}, {row + 1}), pty saw {got[0]}")
        assert got[0] == (LEFT, col + 1, row + 1, "M")


@pytest.fixture(scope="module")
def follow(launch):
    return split(launch, "ghostty-mouse-follow", "F4", "focus-follows-mouse = true\n")


def test_focus_follows_mouse_between_splits(follow):
    first, second = halves(follow)
    follow.focus()

    # Two moves, because a motion event that doesn't move the pointer is
    # ignored (`is_cursor_still` in `ecMouseMotion`).
    before = focused(follow)
    move(*first)
    move(first[0] + 5, first[1] + 5)
    got_first = wait_focus_moves(follow, before)
    assert which_got(follow, "hover1") == got_first

    move(*second)
    move(second[0] + 5, second[1] + 5)
    got_second = wait_focus_moves(follow, [got_first])
    assert which_got(follow, "hover2") == got_second
    new_line(follow)
