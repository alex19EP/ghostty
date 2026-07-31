"""GtkAccessibleText as an AT client sees it.

The dominant failure mode in this subsystem is mixing up byte offsets and
codepoint offsets: AT-SPI is defined entirely in codepoints, while Zig
slices are bytes. Getting it wrong truncates text or crashes the bridge.
Several tests below deliberately compute what the byte-offset answer would
have been and assert we did *not* return it, so a regression cannot pass by
accident on ASCII-only content.
"""

from __future__ import annotations

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

import harness  # noqa: E402

# From the seed script. Chosen so byte length differs from codepoint length:
# combining-free but 2- and 3-byte UTF-8, plus a symbol.
MULTIBYTE = "héllo wörld ✓ 日本語 end"


def test_seeded_lines_are_present(session):
    text = session.text()
    for line in (harness.READY_MARKER, "alpha beta gamma", MULTIBYTE):
        assert line in text, f"{line!r} missing from accessible text"


def test_trailing_blank_rows_are_preserved(session):
    """One '\\n'-delimited row per viewport row, blank rows included.

    `axRefreshCache` deliberately avoids `dumpTextLocked`, which unwraps and
    drops trailing blank rows. Dropping them would leave the bottom of the
    viewport invisible to flat review and misalign `axGetExtents`, which
    derives Y from the newline count.

    The exact row count depends on the window geometry the display gives us,
    so assert the property rather than a number: the seed script writes five
    lines and the rest of the viewport must still be addressable.
    """
    rows = session.text().split("\n")
    trailing_blanks = len(rows) - len([r for r in rows if r.strip()])
    assert rows[-1] == "", "the last viewport row was trimmed away"
    assert trailing_blanks >= 10, (
        f"only {trailing_blanks} blank rows survived in a {len(rows)}-row "
        f"snapshot; trailing blanks are being dropped"
    )


def test_character_count_is_in_codepoints(session):
    """`get_character_count` must count codepoints, not bytes."""
    text = session.text()
    count = Atspi.Text.get_character_count(session.terminal)
    assert count == len(text)
    assert count != len(text.encode("utf-8")), (
        "seed content is pure ASCII — this test can no longer detect a "
        "byte/codepoint mix-up"
    )


def test_get_text_range_over_multibyte_content(session):
    """A codepoint range must slice exactly the characters it names.

    This is the assertion that catches the classic regression. If the
    implementation treated the offsets as bytes it would return a shifted,
    likely mid-character slice.
    """
    text = session.text()
    start = text.index(MULTIBYTE)
    assert (
        Atspi.Text.get_text(session.terminal, start, start + len(MULTIBYTE))
        == MULTIBYTE
    )

    # Everything above is still ASCII, so that range alone cannot tell the two
    # interpretations apart. Repeat it for a range that begins *after* the
    # multi-byte line, where the byte offset and the codepoint offset genuinely
    # diverge — this is the part a regression would fail.
    later = text.index(harness.BARE_URL)
    assert len(text[:later].encode("utf-8")) != later, (
        "seed content no longer puts multi-byte text above the probe range"
    )
    assert (
        Atspi.Text.get_text(session.terminal, later, later + len(harness.BARE_URL))
        == harness.BARE_URL
    )


def test_get_text_slices_inside_a_multibyte_word(session):
    """Sub-word ranges land on character boundaries."""
    text = session.text()
    start = text.index("wörld")
    assert Atspi.Text.get_text(session.terminal, start, start + 5) == "wörld"
    assert Atspi.Text.get_text(session.terminal, start + 1, start + 2) == "ö"


def test_string_at_offset_line_granularity(session):
    """Flat review steps by line; a line must be a whole viewport row."""
    offset = session.offset_of("alpha beta gamma")
    result = Atspi.Text.get_string_at_offset(
        session.terminal, offset, Atspi.TextGranularity.LINE
    )
    assert result.content.strip() == "alpha beta gamma"
    assert result.start_offset <= offset < result.end_offset


def test_string_at_offset_char_granularity_multibyte(session):
    """Character granularity returns one character, not one byte."""
    offset = session.text().index("日本語")
    result = Atspi.Text.get_string_at_offset(
        session.terminal, offset, Atspi.TextGranularity.CHAR
    )
    assert result.content == "日"
    assert result.end_offset - result.start_offset == 1


def test_string_at_offset_word_granularity(session):
    offset = session.offset_of("beta")
    result = Atspi.Text.get_string_at_offset(
        session.terminal, offset, Atspi.TextGranularity.WORD
    )
    assert result.content.strip() == "beta"


def test_rows_have_distinct_vertical_extents(session):
    """Orca groups flat-review zones into lines by Y coordinate.

    `flat_review.Line.on_same_line` compares Y; if every range reported the
    same rect, the whole viewport collapsed into a single unnavigable line.
    """
    text = session.text()
    first = text.index("alpha beta gamma")
    second = text.index(MULTIBYTE)

    rect_a = Atspi.Text.get_range_extents(
        session.terminal, first, first + 5, Atspi.CoordType.WINDOW
    )
    rect_b = Atspi.Text.get_range_extents(
        session.terminal, second, second + 5, Atspi.CoordType.WINDOW
    )

    assert rect_a.height > 0 and rect_b.height > 0
    assert rect_a.height == rect_b.height, "rows should share one cell height"
    assert rect_b.y > rect_a.y, (
        f"row {session.row_of(MULTIBYTE)} is not below row "
        f"{session.row_of('alpha beta gamma')}: y={rect_a.y} vs y={rect_b.y}"
    )
    # One cell height apart per row — the geometry `axGetExtents` promises.
    rows_apart = session.row_of(MULTIBYTE) - session.row_of("alpha beta gamma")
    assert rect_b.y - rect_a.y == rows_apart * rect_a.height


def test_extents_advance_horizontally_within_a_row(session):
    offset = session.offset_of("alpha beta gamma")
    left = Atspi.Text.get_range_extents(
        session.terminal, offset, offset + 1, Atspi.CoordType.WINDOW
    )
    right = Atspi.Text.get_range_extents(
        session.terminal, offset + 6, offset + 7, Atspi.CoordType.WINDOW
    )
    assert right.x > left.x
    assert right.y == left.y
    assert right.x - left.x == 6 * left.width


def test_offset_at_point_round_trips(session):
    """`get_offset_at_point` is the documented inverse of `get_extents`."""
    offset = session.offset_of("gamma")
    rect = Atspi.Text.get_range_extents(
        session.terminal, offset, offset + 1, Atspi.CoordType.WINDOW
    )
    hit = Atspi.Text.get_offset_at_point(
        session.terminal,
        rect.x + rect.width // 2,
        rect.y + rect.height // 2,
        Atspi.CoordType.WINDOW,
    )
    assert hit == offset


def test_default_attributes_describe_the_font(session):
    """Orca reads these to announce font family and size."""
    attrs = Atspi.Text.get_default_attributes(session.terminal)
    assert "family-name" in attrs, attrs
    assert float(attrs["size"]) > 0, attrs


def test_attribute_run_covers_a_range(session):
    """Per-character queries must report a *run*, not a single character.

    Returning a one-character range would make Orca re-query us once per
    character across the whole viewport.
    """
    offset = session.offset_of("alpha beta gamma")
    attrs, start, end = Atspi.Text.get_attribute_run(
        session.terminal, offset, True
    )
    assert start <= offset < end
    assert end - start > 1, "expected a coalesced style run"
