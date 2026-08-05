"""The AT-SPI selection API against a viewport with scrollback behind it.

`test_events.py` covers the selection round trip on a fresh viewport. This
module covers what only shows up once output has scrolled off, plus the one
path GTK's bridge takes that no ordinary client call reaches directly. Both
correspond to bugs live in another terminal today:

- GNOME/vte#2959. GTK implements AddSelection by first asking
  `gtk_accessible_text_get_selection (text, &n_ranges, NULL)` — a NULL
  `ranges` out-parameter, used only to test whether a selection already
  exists (gtkatspitext.c). An implementation that writes through `ranges`
  unconditionally crashes the terminal from a plain Orca keystroke. Ours is
  optional-guarded; these tests are what keeps it that way.
- GNOME/vte#2958. Offsets handed to the selection setter must land on the
  same rows the text getter reported them from. VTE's setter treats them as
  absolute buffer rows while its getter reports viewport-relative ones, so
  once anything scrolls off, AT-SPI selects text the user never asked for.
  We resolve both directions against the same viewport snapshot, and that is
  the invariant these tests pin down.

Both matter to a screen-reader user through Orca's caret navigator and flat
review presenter, which select text as they move (orca#706).
"""

from __future__ import annotations

import time

import gi
import pytest

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

import harness  # noqa: E402

# 200 lines of output, so most of it has scrolled off a 30-row viewport by the
# time the marker lands. The marker goes *last* precisely because the harness
# waits for it in the accessible text; printed first, it would scroll away
# before startup finished.
SCROLL_SEED = f"""#!/bin/sh
i=1
while [ $i -le 200 ]; do
  printf 'line %03d filler text\\n' $i
  i=$((i+1))
done
printf '%s\\n' '{harness.READY_MARKER}'
exec cat
"""


@pytest.fixture(scope="module")
def session(launch):
    """Override the default seed: these tests need scrollback to exist."""
    return launch(SCROLL_SEED)


def settled_text(session, timeout: float = 5.0) -> str:
    """The accessible text, read once the viewport has stopped moving.

    Scroll keys go through XTEST and land on some later frame, so a read
    taken while one is still in flight describes a viewport that no longer
    exists by the time offsets are used against it — the offsets stay valid,
    the rows under them do not. Two identical consecutive reads mean the
    scroll has finished and it is safe to index into the result.
    """
    previous = session.text()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        time.sleep(0.2)
        current = session.text()
        if current == previous:
            return current
        previous = current
    raise AssertionError(f"viewport still moving after {timeout}s")


def test_scrollback_is_not_exposed(session):
    """Precondition for the rest of the module: text really did scroll off.

    Also the statement of what our accessible text is. It is the viewport,
    not the buffer — every offset in this file is only meaningful because
    both directions agree on that.
    """
    text = session.text()
    assert "line 200 filler text" in text, text[-200:]
    assert "line 001 filler text" not in text, (
        "the whole 200-line run fits in the viewport; this session cannot "
        "cover the scrolled case it exists for"
    )


def test_add_selection_with_no_selection(session):
    """AddSelection asks us for the selection with a NULL `ranges` pointer.

    Nothing else in the suite reaches that path: every client-facing call
    passes a real out-parameter. Dereferencing it unconditionally is
    GNOME/vte#2959, and it takes down the terminal — so assert we are still
    alive and still answering, not merely that the call returned.
    """
    text = session.text()
    start = text.index("line 200")
    end = start + len("line 200")

    Atspi.Text.remove_selection(session.terminal, 0)
    accepted = Atspi.Text.add_selection(session.terminal, start, end)

    assert session.proc.poll() is None, "Ghostty died during AddSelection"
    assert session.text(), "Ghostty stopped answering after AddSelection"
    assert accepted, "AddSelection was rejected"


def test_add_selection_with_existing_selection(session):
    """The same NULL-ranges path, down the branch that finds a selection.

    GTK refuses the call in this case (a selection already exists), which is
    fine — but it has to ask us first, and asking must not be fatal.
    """
    text = session.text()
    start = text.index("line 199")
    Atspi.Text.set_selection(session.terminal, 0, start, start + 8)
    assert Atspi.Text.get_n_selections(session.terminal) == 1

    Atspi.Text.add_selection(session.terminal, start + 20, start + 28)

    assert session.proc.poll() is None, "Ghostty died during AddSelection"
    assert session.text(), "Ghostty stopped answering after AddSelection"


def test_selection_count_and_range_agree(session):
    """GetNSelections and GetSelection read the same terminal state."""
    text = session.text()
    start = text.index("line 198")
    Atspi.Text.set_selection(session.terminal, 0, start, start + 8)

    assert Atspi.Text.get_n_selections(session.terminal) == 1
    got = Atspi.Text.get_selection(session.terminal, 0)
    assert (got.start_offset, got.end_offset) == (start, start + 8)


def test_multi_line_selection_with_scrollback_present(session):
    """Select the last three lines while 170 more sit in the scrollback.

    The offsets come from GetText, the selection is applied by SetSelection,
    and the readback is derived from the terminal's own selection pins. If
    those disagreed about where the viewport starts — GNOME/vte#2958 — the
    readback would name a different region, exactly as it does there.
    """
    text = session.text()
    start = text.index("line 197")
    end = text.index("line 200") + len("line 200 filler text")
    requested = text[start:end]
    assert requested.count("\n") == 3, requested

    assert Atspi.Text.set_selection(session.terminal, 0, start, end), (
        "SetSelection rejected a three-line range"
    )

    got = Atspi.Text.get_selection(session.terminal, 0)
    assert (got.start_offset, got.end_offset) == (start, end), (
        f"asked for ({start}, {end}), terminal reports "
        f"({got.start_offset}, {got.end_offset})"
    )
    assert (
        Atspi.Text.get_text(session.terminal, got.start_offset, got.end_offset)
        == requested
    )


def test_selected_text_is_what_gets_copied(session):
    """What the terminal would actually copy, not just what it reports.

    Offsets round-tripping only proves our two mappings are inverses of each
    other; a shared error would cancel out and still highlight the wrong
    rows. So select a line, press copy, then press paste — `cat` echoes the
    clipboard straight back into the viewport, which makes the pasted text
    ground truth for what was really selected.
    """
    text = session.text()
    needle = "line 196 filler text"
    start = text.index(needle)
    assert Atspi.Text.set_selection(session.terminal, 0, start, start + len(needle))

    session.send_key("ctrl+shift+c")
    session.send_key("ctrl+shift+v")

    echoed = session.wait_for_text(
        lambda current: current.rstrip().endswith(needle),
        f"the pasted clipboard ({needle!r}) to echo at the bottom",
        timeout=8.0,
    )
    assert echoed.rstrip().endswith(needle), echoed[-200:]


def test_selection_in_a_scrolled_back_viewport(session):
    """Scroll into the scrollback, then select what is now on screen.

    Scrolling is how a screen-reader user reaches earlier output at all, so
    the viewport-relative mapping has to hold when the viewport is no longer
    at the bottom. And once the selection scrolls back out of view we must
    report no selection rather than the wrong one — our offsets cannot name
    those rows, and inventing an answer is how #2958 misleads its client.
    """
    session.send_key("shift+Page_Up")
    session.wait_for_text(
        lambda current: "line 200 filler text" not in current,
        "the viewport to show scrollback",
        timeout=5.0,
    )

    scrolled = settled_text(session)
    rows = scrolled.splitlines()
    middle = rows[len(rows) // 2].strip()
    assert middle.startswith("line "), scrolled
    needle = middle[:8]
    start = scrolled.index(needle)

    assert Atspi.Text.set_selection(session.terminal, 0, start, start + 8)
    got = Atspi.Text.get_selection(session.terminal, 0)
    assert (got.start_offset, got.end_offset) == (start, start + 8)
    assert (
        Atspi.Text.get_text(session.terminal, got.start_offset, got.end_offset)
        == needle
    )

    session.send_key("shift+Page_Down")
    session.wait_for_text(
        lambda current: "line 200 filler text" in current,
        "the viewport to return to the bottom",
        timeout=5.0,
    )
    settled_text(session)
    assert Atspi.Text.get_n_selections(session.terminal) == 0
