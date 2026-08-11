"""Accessible geometry on a HiDPI display.

Ghostty's core surface works in device pixels: the renderer draws in them, and
the GTK front end multiplies pointer input up into them (`scaledCoordinates`).
GTK's accessibility coordinates are widget space. On a 1x display the two are
the same numbers, so for a long time `axGetExtents` handed the device-pixel
cell metrics straight to GTK and nothing looked wrong — including to every
test here, because Xvfb runs at 1x.

On a scaled display it is very wrong, and it is not a cosmetic wrongness.
Orca builds flat review by asking for each line's rect and keeping the lines
that intersect the widget's allocation. Rects inflated by the scale factor run
out of the bottom of that box after `height / scale` lines, so flat review
silently ends partway down the screen. Three testers reported the same
symptom from that: the tail of the output and the shell prompt are missing
from flat review, and refocusing the window brings them back.

`GDK_SCALE=2` is how that display is reproduced here. It sets an integer scale
factor, which is exactly what `gtk_widget_get_scale_factor` reports and what
the conversion divides by.

These tests assert relationships, not pixel counts — a row is one row tall, the
rows tile the widget without gaps, the whole viewport fits inside the widget —
so they stay true across fonts, cell sizes and padding.
"""

from __future__ import annotations

import pytest

import harness

pytestmark = pytest.mark.usefixtures("primed")

SCALE = 2


@pytest.fixture(scope="module")
def session(launch):
    return launch(
        instance=f"{harness.INSTANCE_NAME}-hidpi",
        env={"GDK_SCALE": str(SCALE)},
    )


@pytest.fixture(scope="module")
def primed(session):
    session.focus()


def _line_rects(session) -> list[tuple[int, tuple]]:
    """(offset, rect) for the first character of every line of the viewport."""
    text = session.text()
    rects = []
    offset = 0
    for line in text.split("\n"):
        # A trailing newline makes `split` yield an empty final element whose
        # offset is past the end; there is no cell there to ask about.
        if offset < len(text):
            rects.append((offset, session.range_extents(offset, offset + 1)))
        offset += len(line) + 1
    return rects


def test_rows_fit_inside_the_widget(session):
    """Every row we report a rect for is inside the terminal's allocation.

    This is the assertion that fails when extents are in device pixels: the
    rows are `SCALE` times too tall, so the bottom of the viewport lands
    outside the widget and Orca drops those lines from flat review.
    """
    widget = session.extents()
    rects = _line_rects(session)
    assert len(rects) > 1, "need a multi-row viewport to say anything"

    overflowing = [
        (offset, rect)
        for offset, rect in rects
        if rect.y + rect.height > widget.y + widget.height
    ]
    assert not overflowing, (
        f"{len(overflowing)} of {len(rects)} rows fall outside the terminal's "
        f"{widget.height}px-tall allocation at scale {SCALE}; "
        f"first is offset {overflowing[0][0]} at {overflowing[0][1]}.\n"
        "Flat review keeps only the lines that intersect the widget, so these "
        "rows are invisible to a screen reader."
    )


def test_rows_tile_without_gaps(session):
    """Consecutive rows are one row-height apart, and each is one row tall.

    A scale conversion applied to the origin but not the size (or the other
    way round) still passes the fits-inside test on a short viewport; this is
    what catches it.
    """
    rects = [rect for _, rect in _line_rects(session)]
    heights = {rect.height for rect in rects}
    assert len(heights) == 1, f"rows have differing heights: {sorted(heights)}"

    row_h = heights.pop()
    assert row_h > 0, "rows have no height"

    strides = {b.y - a.y for a, b in zip(rects, rects[1:])}
    assert strides == {row_h}, (
        f"rows are {sorted(strides)} apart but {row_h} tall — they should "
        "tile exactly, with no gap and no overlap"
    )


def test_the_widget_is_taller_than_the_viewport_it_holds(session):
    """All the rows together fit in the widget, with less than a row to spare.

    The direct statement of the bug: at scale 2 the unconverted viewport was
    twice the height of the widget holding it.
    """
    widget = session.extents()
    rects = [rect for _, rect in _line_rects(session)]
    spanned = (rects[-1].y + rects[-1].height) - rects[0].y

    assert spanned <= widget.height, (
        f"the {len(rects)} rows span {spanned}px inside a {widget.height}px "
        f"widget at scale {SCALE}"
    )
    assert widget.height - spanned < rects[0].height * 2, (
        f"the rows span only {spanned}px of a {widget.height}px widget; "
        "the viewport should very nearly fill it"
    )


def test_point_round_trips_through_the_offset_lookup(session):
    """Asking where a character is and then what is there returns that char.

    `axGetOffset` is the inverse of `axGetExtents` and shares its conversion,
    so a scale bug in either shows up as a mismatch here. This is the path
    that routes a braille cursor or an Orca click to a cell.
    """
    text = session.text()
    rects = _line_rects(session)

    # A row with content on it; a blank row's first cell is a space and any
    # column would satisfy the assertion.
    for offset, rect in rects:
        if offset < len(text) and text[offset] not in (" ", "\n"):
            break
    else:
        pytest.skip("no row starts with a visible character")

    found = session.offset_at_point(
        rect.x + rect.width // 2,
        rect.y + rect.height // 2,
    )
    assert found == offset, (
        f"the centre of the rect for offset {offset} ({text[offset]!r}) maps "
        f"back to offset {found} ({text[found:found + 1]!r})"
    )
