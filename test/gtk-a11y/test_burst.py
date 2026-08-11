"""What an AT client's copy of the text looks like after a burst of output.

Reported independently by two testers on the Orca mailing list: after a lot
of output — a compile, a `meson setup` — flat review loses the tail of the
screen. The last rows and the prompt are simply not there, and switching
away from the window and back restores them.

An AT client does not re-read the whole buffer when it changes; it applies
the `remove`/`insert` events we emit to the copy it already has. So there
are two ways to show it the wrong thing, and these tests separate them:

  - our text is wrong, which `test_text_keeps_the_tail_after_a_burst`
    catches by reading the buffer back over AT-SPI, and
  - our text is right but the events describing how it got there are not,
    which `test_events_reconstruct_the_text_after_a_burst` catches by
    replaying the event stream and comparing.

The second is the one worth having. `a11y_offsets` unit-tests the same
round-trip property over generated viewports, but only over the arithmetic;
this runs it through the real GTK bridge, the real codepoint conversion and
the real cache-aliasing that serves a deleted range back to the client
while the cache already holds the text that replaced it.
"""

from __future__ import annotations

import pytest

import harness


@pytest.fixture(scope="module")
def session(launch):
    return launch(seed=harness.BURST_SEED_SCRIPT)


@pytest.fixture(scope="module", autouse=True)
def primed(session):
    session.focus()
    session.prime_change_events()


def _trigger_burst(session) -> None:
    """Wake the seed script's `read`, which fires the burst."""
    session.type_text("go")
    session.send_key("Return")


def _replay(base: str, records: list[dict]) -> str:
    """Apply recorded text-changed events to `base`, as a client would.

    AT-SPI offsets are codepoint indices, and so is indexing into a Python
    `str`, so this needs no conversion. `detail1` is the offset, `detail2`
    the length, and `any_data` the text inserted or deleted.
    """
    text = base
    for r in records:
        offset, length = r["detail1"], r["detail2"]
        data = r["data"] or ""
        if r["type"].endswith("insert"):
            text = text[:offset] + data + text[offset:]
        else:
            text = text[:offset] + text[offset + length :]
    return text


def test_text_keeps_the_tail_after_a_burst(session):
    """The rows that arrived last are in the accessible text, prompt included."""
    _trigger_burst(session)

    text = session.wait_for_text(
        lambda t: harness.BURST_DONE in t,
        f"{harness.BURST_DONE!r} to reach the accessible text",
        timeout=20.0,
    )

    rows = text.split("\n")
    assert harness.BURST_DONE in rows, (
        f"{harness.BURST_DONE!r} is not a row of its own.\n"
        f"last rows: {rows[-5:]}"
    )

    # The prompt has no trailing newline, so it is the last row and it is
    # what the reporters said was missing.
    done_at = rows.index(harness.BURST_DONE)
    assert rows[done_at + 1 :], "nothing after the done marker; the prompt row is gone"
    assert rows[done_at + 1].startswith(harness.BURST_PROMPT), (
        f"expected the prompt {harness.BURST_PROMPT!r} after the marker, "
        f"got {rows[done_at + 1]!r}"
    )

    # The burst scrolled past the viewport, so the rows just above the marker
    # must be the *last* ones printed, not an earlier stretch left stale.
    last_row = f"burst {harness.BURST_ROWS - 1:03d} filler"
    assert last_row in rows, f"{last_row!r} missing; text ends:\n" + "\n".join(rows[-5:])


def test_events_reconstruct_the_text_after_a_burst(session):
    """Replaying the emitted events onto the old text must yield the new text.

    If this fails, an AT client's copy has drifted from ours and will stay
    wrong until something makes it rebuild from scratch — which, in Orca, is
    a focus change. That is exactly the reported symptom.
    """
    before = session.text()

    with harness.Events("object:text-changed") as events:
        _trigger_burst(session)
        session.wait_for_text(
            lambda t: harness.BURST_DONE in t,
            f"{harness.BURST_DONE!r} to reach the accessible text",
            timeout=20.0,
        )
        events.pump(3.0)

    after = session.text()
    assert events.records, "a burst of output produced no text-changed events at all"

    # Orca makes one blocking D-Bus call per visible line for every event it
    # processes, so event count is the terminal's half of whether a screen
    # reader can keep up — the question Orca's maintainer asked directly on
    # the list. The change-notify probe coalesces a burst to the frames that
    # actually rendered: 200 rows cost 4 events here. The bound is loose
    # because frame timing decides the exact figure; what it pins is the
    # order of magnitude, i.e. that we are not emitting one event per row.
    assert len(events.records) <= harness.BURST_ROWS // 10, (
        f"{len(events.records)} events for {harness.BURST_ROWS} rows of output; "
        "the burst is no longer being coalesced\n" + events.summary()
    )

    replayed = _replay(before, events.records)
    assert replayed == after, (
        "the event stream does not reconstruct the accessible text.\n"
        f"{len(events.records)} events\n"
        f"replayed tail: {replayed[-200:]!r}\n"
        f"actual tail:   {after[-200:]!r}\n"
        f"{events.summary()}"
    )
