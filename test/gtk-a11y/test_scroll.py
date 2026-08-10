"""Scrolling the viewport, as an AT client sees it.

Reported on the Orca mailing list against this branch: scrolling back one
line made Orca read the whole screen, where a VTE terminal announces only
the line that scrolled into view. The cause was that the shift detector
only ever looked for content leaving the *top* of the viewport — the shape
of command output — so scrolling backwards fell through to the generic
prefix/suffix diff, which for a one-line shift shares almost nothing at
either end and therefore rewrites everything.

`a11y_offsets` unit-tests the arithmetic. What it cannot show is that the
events reaching a client are the small ones, which is the only part the
user actually experiences, so that is what these tests assert.
"""

from __future__ import annotations

import pytest

import harness


# One row of the seed is `row NNN filler` plus its newline. A one-line
# shift should cost about two of those — one leaving, one arriving — so
# this bounds "a couple of rows" without pinning the exact width.
ROW_BUDGET = 2 * (len("row 000 filler") + 1) + 8


@pytest.fixture(scope="module")
def session(launch):
    return launch(seed=harness.SCROLL_SEED_SCRIPT)


@pytest.fixture(scope="module", autouse=True)
def primed(session):
    """Absorb the one-off full-viewport announcement before any test runs.

    Scrolling rather than typing, because typing scrolls the viewport back
    to the bottom and these tests care about where it is. A round trip
    leaves the viewport exactly where it started.
    """
    with harness.Events("object:text-changed") as events:
        session.send_key("F9")
        events.pump(2.0)
        session.send_key("F10")
        events.pump(2.0)


def churn(events) -> int:
    return sum(record["detail2"] for record in events.records)


def test_scroll_back_announces_only_the_new_line(session):
    """The regression itself.

    Before the downward-shift path existed this emitted a remove and an
    insert covering the entire viewport, and Orca read the whole screen for
    one line of movement.
    """
    before = session.text()

    with harness.Events("object:text-changed") as events:
        session.send_key("F9")
        events.pump(2.0)

    after = session.text()
    assert after != before, (
        "the viewport did not move; F9 is bound to scroll_page_lines:-1 and "
        "the seed must leave rows above the viewport to scroll back to"
    )
    assert events.records, f"scrolling emitted no events at all:\n{events.summary()}"
    assert churn(events) <= ROW_BUDGET, (
        f"{churn(events)} characters churned for a one-line scroll back "
        f"(viewport is {len(before)} characters) — the diff is re-announcing "
        f"the whole screen:\n{events.summary()}"
    )


def test_scroll_back_inserts_at_the_top(session):
    """Shape, not just size: the new row arrives at offset 0.

    Orca decides what to speak from where the insert landed. A correctly
    sized diff reported at the wrong offset still reads out the wrong line.
    """
    with harness.Events("object:text-changed") as events:
        session.send_key("F9")
        events.pump(2.0)

    inserts = events.inserts()
    assert len(inserts) == 1, (
        f"expected one insert for one scrolled line, got {len(inserts)}:"
        f"\n{events.summary()}"
    )
    assert inserts[0]["detail1"] == 0, (
        f"insert landed at offset {inserts[0]['detail1']}, expected 0 — a row "
        f"scrolling in at the top is an insert at the start of the text:"
        f"\n{events.summary()}"
    )

    first_row = session.text().split("\n", 1)[0]
    assert (inserts[0]["data"] or "").startswith(first_row), (
        f"inserted {inserts[0]['data']!r} but the top row is now {first_row!r}"
    )


def test_scroll_back_deletes_from_the_bottom(session):
    """The other half of the pair: the last row falls off the end."""
    before = session.text()
    last_row = before.rsplit("\n", 1)[-1] or before.rsplit("\n", 2)[-2]

    with harness.Events("object:text-changed") as events:
        session.send_key("F9")
        events.pump(2.0)

    deletes = events.deletes()
    assert len(deletes) == 1, (
        f"expected one delete for one scrolled line, got {len(deletes)}:"
        f"\n{events.summary()}"
    )
    assert deletes[0]["detail1"] > 0, (
        f"delete landed at offset {deletes[0]['detail1']}, expected the tail "
        f"of the text:\n{events.summary()}"
    )
    assert last_row in (deletes[0]["data"] or ""), (
        f"deleted {deletes[0]['data']!r}, expected it to cover the bottom row "
        f"{last_row!r} — the bridge reads a remove back out of the *old* "
        f"snapshot, so a mismatch here means the cache was not aliased:"
        f"\n{events.summary()}"
    )


def test_scroll_forward_still_announces_only_the_new_line(session):
    """The upward shift must survive the addition of its mirror image.

    Both directions are now detected, and either could claim a change the
    other should have had; a forward scroll that starts reporting itself as
    an insert at offset 0 would be silently wrong in exactly the way the
    original bug was.
    """
    with harness.Events("object:text-changed") as events:
        session.send_key("F10")
        events.pump(2.0)

    assert events.records, f"scrolling forward emitted no events:\n{events.summary()}"
    assert churn(events) <= ROW_BUDGET, (
        f"{churn(events)} characters churned for a one-line scroll forward:"
        f"\n{events.summary()}"
    )

    inserts = events.inserts()
    assert len(inserts) == 1, f"expected one insert:\n{events.summary()}"
    assert inserts[0]["detail1"] > 0, (
        f"a forward scroll appends at the bottom, so the insert offset must "
        f"be past the start, not {inserts[0]['detail1']}:\n{events.summary()}"
    )


def test_round_trip_restores_the_viewport(session):
    """Scroll back and forward again; the text must come back identical.

    The events are a description of an edit, and a description that does
    not reconstruct the new text is a description Orca will act on wrongly
    even when every individual assertion above passes.
    """
    before = session.text()

    session.send_key("F9")
    session.wait_for_text(
        lambda text: text != before,
        "the viewport to scroll back",
    )

    session.send_key("F10")
    restored = session.wait_for_text(
        lambda text: text == before,
        "the viewport to scroll forward again",
    )
    assert restored == before
