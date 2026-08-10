"""Caret mode as a screen reader experiences it.

Caret mode gives the keyboard a cursor that roams independently of the
terminal cursor, so a user can navigate to output already on screen and
select from there. `test_keyboard_selection.py` covers the case where the
anchor is the terminal cursor; this covers the case where it moves.

The reason this module exists is a failure mode with no visual symptom at
all. Moving the caret without selecting produces *no selection*, so it emits
no `object:text-selection-changed` — the channel every assertion in
`test_keyboard_selection.py` relies on. If the AT-SPI caret does not follow
the roaming caret, then a sighted user sees a block cursor gliding around the
scrollback while a screen reader user hears nothing whatsoever, and every
Zig-level test still passes because the text is unchanged.

So `test_moving_the_caret_moves_the_at_spi_caret` is the load-bearing test
here. The upstream implementation this is built on (ghostty#12326) touches no
apprt files at all, which is precisely the bug these tests exist to prevent.
"""

from __future__ import annotations

import time

import gi
import pytest

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

import harness  # noqa: E402


# Distinct words on distinct rows so a caret offset can be turned back into a
# row without ambiguity. `cat` holds the pty open; in caret mode keystrokes
# never reach it, which is itself worth having a test for.
SEED = f"""#!/bin/sh
printf 'alpha bravo charlie\\n'
printf 'delta echo foxtrot\\n'
printf 'golf hotel india\\n'
printf '%s\\n' '{harness.READY_MARKER}'
exec cat
"""


@pytest.fixture(scope="module")
def session(launch):
    return launch(SEED)


@pytest.fixture(autouse=True)
def caret_mode(session):
    """Enter caret mode before each test, and leave it afterwards.

    Entering is idempotent (`enter_caret_mode` is a no-op when already
    active), so this is safe even if a test left the mode on. Escape exits
    via the built-in caret table rather than reaching the pty.
    """
    session.send_key("F7")
    time.sleep(0.3)
    yield session
    session.send_key("Escape")
    time.sleep(0.3)


def caret(session) -> int:
    return Atspi.Text.get_caret_offset(session.terminal)


def line_at(session, offset: int) -> str:
    """The viewport line containing `offset`, for readable assertions."""
    text = session.text()
    start = text.rfind("\n", 0, offset) + 1
    end = text.find("\n", offset)
    return text[start : end if end != -1 else len(text)]


def test_entering_caret_mode_puts_the_caret_at_the_terminal_cursor(session):
    """Precondition: caret mode starts where the user already is."""
    assert 0 <= caret(session) <= len(session.text())


def test_moving_the_caret_moves_the_at_spi_caret(session):
    """The load-bearing test: navigation without selection must be audible.

    No selection exists, so `object:text-selection-changed` cannot carry
    this. A caret-moved event and a changed caret offset are the only things
    a screen reader has to go on.
    """
    before = caret(session)

    with harness.Events("object:text-caret-moved") as events:
        session.send_key("Up")
        session.send_key("Up")
        events.pump(2.0)

    after = caret(session)
    print(f"\n  caret {before} -> {after}, {len(events.records)} caret-moved events")
    print(f"  landed on: {line_at(session, after)!r}")

    assert after != before, (
        "moving the caret did not move the AT-SPI caret — a screen reader "
        "user gets no feedback at all while navigating, because there is no "
        "selection to report either"
    )
    assert events.records, (
        "the caret moved but no object:text-caret-moved was emitted, so Orca "
        "never learns about it"
    )


def test_caret_moves_between_rows(session):
    """Up/down should land on different lines, not just different offsets."""
    session.send_key("Up")
    time.sleep(0.3)
    first = line_at(session, caret(session))

    session.send_key("Up")
    time.sleep(0.3)
    second = line_at(session, caret(session))

    assert first != second, (
        f"two Up presses stayed on the same line ({first!r}); the caret is "
        f"not moving by rows"
    )


def test_selection_from_the_caret_follows_it(session):
    """`v` anchors at the caret, and further movement extends the selection.

    This is the payoff for the whole feature: the anchor is somewhere the
    user navigated to, not wherever the shell happened to leave the cursor.
    """
    session.send_key("Up")
    session.send_key("Up")
    time.sleep(0.3)

    with harness.Events("object:text-selection-changed") as events:
        session.send_key("v")
        time.sleep(0.3)
        session.send_key("Right")
        session.send_key("Right")
        events.pump(2.0)

    assert Atspi.Text.get_n_selections(session.terminal) == 1, (
        "'v' in caret mode produced no selection"
    )
    r = Atspi.Text.get_selection(session.terminal, 0)
    selected = Atspi.Text.get_text(session.terminal, r.start_offset, r.end_offset)
    print(f"\n  selection {r.start_offset}-{r.end_offset} = {selected!r}")
    print(f"  selection-changed events: {len(events.records)}")

    assert len(selected) > 1, (
        f"selection did not grow past the anchor cell (got {selected!r})"
    )
    assert events.records, "selection changes in caret mode were not announced"


def test_caret_mode_swallows_keys_instead_of_typing_them(session):
    """Navigation keys must not reach the shell.

    `j`/`k` are movement in caret mode. If they leaked to the pty, `cat`
    would echo them into the viewport, corrupting the very text the user is
    trying to read.
    """
    before = session.text()
    session.send_key("j")
    session.send_key("k")
    time.sleep(0.5)

    assert session.text() == before, (
        "caret-mode keys reached the pty and changed the viewport; they must "
        "be swallowed"
    )


def test_shift_arrow_selects_without_needing_v(session):
    """The universal selection idiom must work here too.

    Before `move_caret_select` existed the caret table's `catch_all=ignore`
    swallowed shift+arrow outright: no caret movement, no selection, nothing.
    That left `v` as the only way in, which assumes vim conventions, and it
    also discarded the keystroke shape Orca classifies best — it treats
    shift+arrow as caret selection and announces the selected text.
    """
    session.send_key("Up")
    time.sleep(0.3)
    assert Atspi.Text.get_n_selections(session.terminal) == 0, (
        "a selection already existed, so this proves nothing"
    )

    with harness.Events("object:text-selection-changed") as events:
        session.send_key("shift+Right")
        session.send_key("shift+Right")
        events.pump(2.0)

    assert Atspi.Text.get_n_selections(session.terminal) == 1, (
        "shift+Right in caret mode produced no selection — it was most "
        "likely swallowed by the caret table's catch_all"
    )
    r = Atspi.Text.get_selection(session.terminal, 0)
    selected = Atspi.Text.get_text(session.terminal, r.start_offset, r.end_offset)
    print(f"\n  shift+Right x2 selected {selected!r}, {len(events.records)} events")

    assert len(selected) > 1, (
        f"selection did not grow with repeated presses (got {selected!r}); "
        f"the anchor is being reset on every keypress"
    )
    assert events.records, "shift+arrow selection was not announced"


# Row 0 of the seed, used by the line-boundary tests below.
FIRST_ROW = "alpha bravo charlie"


def test_end_lands_on_the_last_character_not_the_last_column(session):
    """End must mean end of text, not the far edge of the window.

    A terminal row is always full width, but the accessible text trims
    trailing blanks — so a caret parked in column 79 of a 19-character row
    reports the same offset as one at the end of the text, and End looks
    like it did nothing.
    """
    session.send_key("ctrl+Home")
    time.sleep(0.3)
    assert caret(session) == 0, "ctrl+Home did not reach the top-left"

    session.send_key("End")
    time.sleep(0.3)
    offset = caret(session)

    assert Atspi.Text.get_text(session.terminal, offset, offset + 1) == FIRST_ROW[-1], (
        f"End put the caret at {offset}, which is not the last character of "
        f"{FIRST_ROW!r}"
    )
    assert Atspi.Text.get_text(session.terminal, offset + 1, offset + 2) == "\n", (
        "End overshot past the end of the line"
    )


def test_home_returns_to_the_start_of_the_line(session):
    session.send_key("ctrl+Home")
    session.send_key("Down")
    session.send_key("End")
    time.sleep(0.4)
    end = caret(session)

    session.send_key("Home")
    time.sleep(0.3)
    start = caret(session)

    assert start < end, f"Home moved to {start}, not before End's {end}"
    assert Atspi.Text.get_text(session.terminal, start, start + 1) != "\n", (
        "Home landed on the line break rather than the first character"
    )


def test_right_never_stalls_in_the_trailing_blanks(session):
    """The caret must not walk into space the accessible text discards.

    Every column past the last character maps to the same offset, so a
    caret out there reports an identical position no matter how many times
    Right is pressed. To a screen reader user the caret has vanished or
    stuck on the last letter — which is exactly how it was reported.
    """
    session.send_key("ctrl+Home")
    time.sleep(0.3)

    seen = [caret(session)]
    for _ in range(len(FIRST_ROW) + 6):
        session.send_key("Right")
        time.sleep(0.1)
        seen.append(caret(session))

    stalls = [(i, a) for i, (a, b) in enumerate(zip(seen, seen[1:])) if a == b]
    print(f"\n  offsets while walking off the end of row 0: {seen}")
    assert not stalls, (
        f"the caret reported the same offset twice in a row at {stalls}; it "
        f"is moving through cells the accessible text does not distinguish"
    )


def test_right_at_end_of_line_moves_to_the_next_row(session):
    session.send_key("ctrl+Home")
    session.send_key("End")
    time.sleep(0.4)
    before = line_at(session, caret(session))

    session.send_key("Right")
    time.sleep(0.3)
    after = line_at(session, caret(session))

    assert after != before, (
        f"Right at the end of {before!r} stayed on the same line; it should "
        f"continue onto the next row"
    )


def selected(session):
    """The selected text, or None when there is no selection."""
    if Atspi.Text.get_n_selections(session.terminal) < 1:
        return None
    r = Atspi.Text.get_selection(session.terminal, 0)
    return Atspi.Text.get_text(session.terminal, r.start_offset, r.end_offset)


def test_releasing_shift_stops_selecting(session):
    """A shift-started selection must not keep growing once shift is let go.

    This is the text-widget contract, and the one Windows Terminal's mark
    mode follows: shift+arrow expands, plain arrow moves and collapses.
    Extending unconditionally -- which is what caret mode did before -- has
    no precedent anywhere, and left a user selecting text they thought they
    had stopped selecting.
    """
    session.send_key("ctrl+Home")
    time.sleep(0.3)

    for _ in range(3):
        session.send_key("shift+Right")
        time.sleep(0.15)
    grown = selected(session)
    assert grown is not None and len(grown) > 1, (
        f"shift+Right did not build a selection (got {grown!r})"
    )

    session.send_key("Right")
    time.sleep(0.3)

    assert selected(session) is None, (
        f"a plain Right left the selection {selected(session)!r} in place; "
        f"releasing shift must stop the selection growing"
    )


def test_v_selection_keeps_following_plain_movement(session):
    """The other idiom, which must survive the fix above.

    `v` is vim's visual mode: it is sticky on purpose, and plain movement
    keeps extending until the selection is ended. If the collapse rule were
    applied unconditionally, `v` would do nothing useful at all.
    """
    session.send_key("ctrl+Home")
    time.sleep(0.3)

    session.send_key("v")
    time.sleep(0.3)
    anchored = selected(session)
    assert anchored is not None, "'v' did not start a selection"

    for _ in range(3):
        session.send_key("Right")
        time.sleep(0.15)
    grown = selected(session)

    assert grown is not None, "plain movement cleared a 'v' selection"
    assert len(grown) > len(anchored), (
        f"'v' selection did not grow with plain movement: "
        f"{anchored!r} -> {grown!r}"
    )

    # And `v` again ends it, leaving plain movement inert once more.
    session.send_key("v")
    time.sleep(0.3)
    assert selected(session) is None, "second 'v' did not clear the selection"
