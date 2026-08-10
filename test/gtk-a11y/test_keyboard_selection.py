"""Starting a selection from the keyboard, as an AT client observes it.

`start_selection` anchors a one-cell selection on the terminal cursor. On its
own that is barely a feature; what makes it one is that Ghostty already binds
shift + arrows, home, end and the page keys to `adjust_selection`, and those
binds are `performable` — they return false and fall through to the shell
whenever no selection exists. So the anchor is the missing half, and these
tests are written against the *default* binds rather than test-only ones,
because "the keys you already have start working" is the actual claim.

The reason this lives at the AT-SPI layer and not in a Zig unit test: the
question that decides whether the feature is usable by ear is not whether the
selection is correct, it is what a screen reader is *told* as the selection
grows. `test_what_orca_is_told` measures exactly that and asserts only what
must hold, printing the rest. Its output is evidence for a design decision
still open at the time of writing — whether the AT-SPI caret should follow
the selection's moving end the way an ordinary text widget's caret does.
"""

from __future__ import annotations

import gi
import pytest

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

import harness  # noqa: E402


# Two rows of known words, then the marker, then the cursor parked *on* real
# text rather than past the end of a line. Anchoring on a trailing blank would
# make every offset assertion below an argument about how blanks are exposed,
# which is a different test's job.
#
# The final CUP puts the cursor at row 2, column 7 (both 1-based), i.e. the "e"
# of "echo". `cat` keeps the pty open without echoing anything unprompted.
SEED = f"""#!/bin/sh
printf 'alpha bravo charlie\\n'
printf 'delta echo foxtrot\\n'
printf '%s\\n' '{harness.READY_MARKER}'
printf '\\033[2;7H'
exec cat
"""

# The cell the cursor sits on, and the word it starts.
ANCHOR_CHAR = "e"
ANCHOR_WORD = "echo"


@pytest.fixture(scope="module")
def session(launch):
    """Override the default seed: these tests need the cursor on known text."""
    return launch(SEED)


@pytest.fixture(autouse=True)
def anchored(session):
    """Re-anchor before every test.

    `start_selection` replaces any existing selection, so pressing it is
    itself the reset — no escape key, no teardown that could leak a stray
    keystroke into `cat`. That this works at all is the re-anchoring
    behaviour, which `test_reanchors_on_a_second_press` pins down properly.
    """
    session.send_key("F8")
    return session


def selection(session):
    """The selected range and its text, or None if nothing is selected."""
    if Atspi.Text.get_n_selections(session.terminal) < 1:
        return None
    r = Atspi.Text.get_selection(session.terminal, 0)
    return (
        r.start_offset,
        r.end_offset,
        Atspi.Text.get_text(session.terminal, r.start_offset, r.end_offset),
    )


def test_the_seed_parked_the_cursor_on_known_text(session):
    """Precondition. If this fails, every offset below is meaningless."""
    text = session.text()
    assert ANCHOR_WORD in text, f"seed text missing {ANCHOR_WORD!r}: {text!r}"

    caret = Atspi.Text.get_caret_offset(session.terminal)
    assert Atspi.Text.get_text(session.terminal, caret, caret + 1) == ANCHOR_CHAR, (
        f"cursor is not on the {ANCHOR_CHAR!r} of {ANCHOR_WORD!r}; the CUP in "
        f"the seed did not land where expected"
    )


def test_start_selection_selects_the_cursor_cell(session):
    """The anchor is one cell, and it is the cell under the cursor."""
    assert selection(session) is not None, (
        "F8 produced no selection at all — start_selection did not reach the "
        "surface, or the binding was not consumed"
    )
    start, end, text = selection(session)
    assert text == ANCHOR_CHAR, f"selected {text!r}, expected {ANCHOR_CHAR!r}"
    assert end - start == 1, f"anchor spans {end - start} codepoints, expected 1"


def test_default_shift_arrow_binds_extend_the_anchor(session):
    """The point of the feature: no new binds needed beyond the anchor.

    shift+Right is a Ghostty default (`adjust_selection:right`). Before an
    anchor exists it is unconsumed and falls through to the shell; this
    asserts that once one exists, the default bind does the work.
    """
    session.send_key("shift+Right")
    session.wait_for_text(lambda _: selection(session)[2] != ANCHOR_CHAR, "the selection to grow")

    _, _, text = selection(session)
    assert text == "ec", f"shift+Right grew the selection to {text!r}, expected 'ec'"


def test_selection_extends_backwards_into_earlier_output(session):
    """Growing upwards is how a keyboard user reaches output above the prompt.

    The cursor sits at the *end* of a session's output, so a selection that
    could only grow forwards would be useless for copying anything already
    printed. Ghostty selections may run backwards, so shift+Up walks the end
    pin above the anchor and the span covers the rows in between.
    """
    session.send_key("shift+Up")
    session.wait_for_text(lambda _: selection(session)[2] != ANCHOR_CHAR, "the selection to grow")

    _, _, text = selection(session)
    assert "bravo" in text or "charlie" in text, (
        f"shift+Up selected {text!r}, which contains nothing from the row "
        f"above — the selection did not extend backwards"
    )


def test_reanchors_on_a_second_press(session):
    """Pressing it again collapses back to the cursor cell.

    Chosen over no-op deliberately: a user who cannot see the current
    selection needs a key that always lands them somewhere known.
    """
    session.send_key("shift+Right")
    session.send_key("shift+Right")
    session.wait_for_text(lambda _: len(selection(session)[2]) > 1, "the selection to grow")

    session.send_key("F8")
    session.wait_for_text(lambda _: len(selection(session)[2]) == 1, "the selection to collapse")

    _, _, text = selection(session)
    assert text == ANCHOR_CHAR, f"re-anchor left {text!r}, expected {ANCHOR_CHAR!r}"


def test_what_orca_is_told(session):
    """Measurement, not policy: what an AT actually receives while selecting.

    Asserts only the one thing that must be true for a screen reader to
    notice anything at all — that extending the selection is announced. The
    caret's behaviour is *reported* rather than asserted, because whether it
    should move is the open design question this test exists to inform, and
    pinning today's answer here would turn a deliberate change into a
    regression.
    """
    caret_before = Atspi.Text.get_caret_offset(session.terminal)

    with harness.Events(
        "object:text-selection-changed", "object:text-caret-moved"
    ) as events:
        session.send_key("shift+Up")
        session.send_key("shift+Up")
        events.pump(2.0)

    caret_after = Atspi.Text.get_caret_offset(session.terminal)
    sel_events = events.of_type("text-selection-changed")
    caret_events = events.of_type("text-caret-moved")

    print("\n--- what an AT sees for two shift+Up presses ---")
    print(f"  selection-changed events: {len(sel_events)}")
    print(f"  caret-moved events:       {len(caret_events)}")
    print(f"  caret offset:             {caret_before} -> {caret_after}")
    print(f"  final selection:          {selection(session)!r}")

    assert sel_events, (
        "extending the selection emitted no object:text-selection-changed, so "
        "a screen reader has no way to know anything happened"
    )
