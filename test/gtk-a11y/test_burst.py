"""What an AT client's copy of the text looks like after a burst of output.

Reported independently by three testers on the Orca mailing list: after a lot
of output — a compile, a `meson setup`, a directory listing — flat review loses
the tail of the screen. The last rows and the prompt are simply not there, and
switching away from the window and back restores them.

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

Both run twice, over an ASCII burst and a multi-byte one. The third reporter
blamed non-ASCII specifically, and on ASCII the bug he describes is unhittable
by construction: byte offset, codepoint offset and column are all the same
number, so the conversions we would have to get wrong cannot be observed. The
`unicode` case is the one where they disagree — see `UNICODE_BURST_SEED_SCRIPT`.
"""

from __future__ import annotations

from dataclasses import dataclass

import pytest

import harness


@dataclass(frozen=True)
class Case:
    """A burst seed plus the strings its output can be recognised by."""

    instance: str
    seed: str
    done: str
    prompt: str
    last_row: str


CASES = {
    "ascii": Case(
        instance=f"{harness.INSTANCE_NAME}-ascii",
        seed=harness.BURST_SEED_SCRIPT,
        done=harness.BURST_DONE,
        prompt=harness.BURST_PROMPT,
        last_row=harness.burst_row(harness.BURST_ROW_FMT, harness.BURST_ROWS - 1),
    ),
    "unicode": Case(
        instance=f"{harness.INSTANCE_NAME}-unicode",
        seed=harness.UNICODE_BURST_SEED_SCRIPT,
        done=harness.UNICODE_BURST_DONE,
        prompt=harness.UNICODE_BURST_PROMPT,
        last_row=harness.burst_row(
            harness.UNICODE_BURST_ROW_FMT, harness.BURST_ROWS - 1
        ),
    ),
}


@pytest.fixture(scope="module", params=list(CASES), ids=list(CASES))
def case(request) -> Case:
    return CASES[request.param]


@pytest.fixture(scope="module")
def session(launch, case):
    """One Ghostty per case. Both stay up until the module is done, so they
    need distinct instance names to stay distinguishable, and the focus claim
    in `primed` is what decides which one the keystrokes reach."""
    return launch(seed=case.seed, instance=case.instance)


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


def test_text_keeps_the_tail_after_a_burst(session, case):
    """The rows that arrived last are in the accessible text, prompt included."""
    _trigger_burst(session)

    text = session.wait_for_text(
        lambda t: case.done in t,
        f"{case.done!r} to reach the accessible text",
        timeout=20.0,
    )

    rows = text.split("\n")
    assert case.done in rows, (
        f"{case.done!r} is not a row of its own.\nlast rows: {rows[-5:]}"
    )

    # The prompt has no trailing newline, so it is the last row and it is
    # what the reporters said was missing.
    done_at = rows.index(case.done)
    assert rows[done_at + 1 :], "nothing after the done marker; the prompt row is gone"
    assert rows[done_at + 1].startswith(case.prompt), (
        f"expected the prompt {case.prompt!r} after the marker, "
        f"got {rows[done_at + 1]!r}"
    )

    # The burst scrolled past the viewport, so the rows just above the marker
    # must be the *last* ones printed, not an earlier stretch left stale.
    assert case.last_row in rows, (
        f"{case.last_row!r} missing; text ends:\n" + "\n".join(rows[-5:])
    )


def test_events_reconstruct_the_text_after_a_burst(session, case):
    """Replaying the emitted events onto the old text must yield the new text.

    If this fails, an AT client's copy has drifted from ours and will stay
    wrong until something makes it rebuild from scratch — which, in Orca, is
    a focus change. That is exactly the reported symptom.
    """
    before = session.text()

    with harness.Events("object:text-changed") as events:
        _trigger_burst(session)
        session.wait_for_text(
            lambda t: case.done in t,
            f"{case.done!r} to reach the accessible text",
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
