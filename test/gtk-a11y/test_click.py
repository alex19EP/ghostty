"""The synthetic click behind `set_caret_position`.

A braille display's cursor-routing keys arrive as AT-SPI `SetCaretOffset`.
A terminal has no settable caret — the program behind the pty owns it — so
Ghostty answers by dispatching a left click on the cell that holds the
offset (`axSetCaretPosition`). Whether that call is *accepted* is checked in
test_events.py; what matters to a user routing to a word is whether the click
lands on that word.

So this module asks the terminal to tell us. The seed pty turns on mouse
reporting, and the tty echoes every report Ghostty sends into the viewport,
where the accessible text picks it up. The coordinates a test reads back are
the ones the program behind the pty would have received.
"""

from __future__ import annotations

import re
import unicodedata

import gi
import pytest

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

import harness  # noqa: E402

# An SGR mouse report as it appears in the viewport after the tty echoed it:
# ESC shows up as `^[` (ECHOCTL), `M` marks a press and `m` a release, and the
# coordinates are 1-based columns and rows.
REPORT = re.compile(r"\^\[\[<(\d+);(\d+);(\d+)([Mm])")

# SGR button code for the left button, which is what `axSetCaretPosition`
# synthesizes.
LEFT = 0


@pytest.fixture(scope="module")
def session(launch):
    """Override the default fixture: this module needs mouse reporting on."""
    return launch(harness.MOUSE_SEED_SCRIPT)


def reports(text: str) -> list[tuple[int, int, int, str]]:
    """Every echoed mouse report in `text`, oldest first."""
    return [
        (int(button), int(col), int(row), kind)
        for button, col, row, kind in REPORT.findall(text)
    ]


def columns(text: str) -> int:
    """How many terminal cells `text` occupies.

    Ground truth for the tests below, and deliberately *not* how the code
    under test computes a column: `axSetCaretPosition` counts codepoints. On
    ASCII the two agree, which is why a wide character is the case that can
    tell them apart.
    """
    def width(ch: str) -> int:
        if unicodedata.combining(ch):
            return 0
        return 2 if unicodedata.east_asian_width(ch) in "WF" else 1

    return sum(width(ch) for ch in text)


def cell_of(text: str, needle: str) -> tuple[int, int]:
    """The (row, column) where `needle` starts on screen, both 0-based.

    The row comes from the accessible text, which is one '\\n'-delimited row
    per viewport row. The column is a cell count, not a codepoint count — see
    `columns`.
    """
    index = text.index(needle)
    row = text[:index].count("\n")
    row_start = text.rfind("\n", 0, index) + 1
    return row, columns(text[row_start:index])


def route_to(session, needle: str) -> list[tuple[int, int, int, str]]:
    """Route the caret to `needle` and return the reports that click produced.

    Reports accumulate in the viewport as tests run, so this snapshots what is
    already there and returns only what is new.
    """
    seen = len(reports(session.text()))

    assert Atspi.Text.set_caret_offset(session.terminal, session.offset_of(needle)), (
        "SetCaretOffset returned FALSE: the set_caret_position vfunc is not "
        "installed, so braille cursor routing does nothing"
    )

    text = session.wait_for_text(
        lambda t: len(reports(t)) > seen,
        f"the pty to report a click after routing to {needle!r}",
    )
    return reports(text)[seen:]


def test_routing_clicks_the_cell_holding_the_offset(session):
    """The whole point: the click lands on the routed-to cell, not near it."""
    row, col = cell_of(session.text(), "epsilon")

    new = route_to(session, "epsilon")

    assert new == [
        (LEFT, col + 1, row + 1, "M"),
        (LEFT, col + 1, row + 1, "m"),
    ], f"expected a press and release on 1-based cell ({col + 1}, {row + 1}), got {new}"


@pytest.mark.parametrize("needle", ["alpha", "gamma", "delta", "zeta"])
def test_routing_tracks_both_row_and_column(session, needle):
    """Distinct targets, distinct cells.

    Row and column are worth checking together: a mapping that ignores the
    newline count reports every row as the first one, and a mapping that
    forgets `size.padding.{left,top}` is off by a fixed amount in both axes —
    both of which land a routing key on the wrong word while still looking
    like a working click.
    """
    row, col = cell_of(session.text(), needle)

    press = [r for r in route_to(session, needle) if r[3] == "M"]

    assert press == [(LEFT, col + 1, row + 1, "M")]


def test_routing_past_a_wide_character(session):
    """Routing to a word that sits after CJK text on the same row.

    `a11y_text.build` skips spacer cells, so a double-width character is one
    codepoint in the snapshot but two columns on screen. Everything that maps
    between offsets and the grid used to equate codepoint index with column,
    which put this click three columns short — on `wide 日本語 tail`, routing
    to "tail" clicked column 10 instead of 13, one short per CJK character.
    The row was never affected; only the column drifted.

    The widths now come from the cell walk (`a11y_offsets.CellWidths`), and
    this is the end-to-end guard on that: it fails again if the width data
    stops being recorded, stops reaching `axSetCaretPosition`, or drifts out
    of alignment with the text.
    """
    row, col = cell_of(session.text(), "tail")

    press = [r for r in route_to(session, "tail") if r[3] == "M"]

    assert press == [(LEFT, col + 1, row + 1, "M")]
