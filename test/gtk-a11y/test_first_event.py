"""The first change event after a client starts reading.

Change events are diffed against the text last notified. Before any
notification there is nothing to diff against, so the first frame after a
client attached used to be reported as the whole viewport inserted at offset
0: text the client had just read, announced again as new output. This module
launches its own Ghostty with a listener already registered, so it sees that
first event, which every other module's session has already swallowed.
"""

from __future__ import annotations

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

import harness  # noqa: E402


def test_first_event_is_incremental(launch):
    """No insert re-announces the whole viewport.

    `Session.start` polls the text until the seed has printed, so the first
    read happens during startup, and typing afterwards forces a frame even if
    startup produced none after that read. A whole-viewport insert spans
    every row separator; a real diff against what the client read never does,
    because the blank rows below the output are a common suffix.
    """
    Atspi.init()
    with harness.Events("object:text-changed") as events:
        session = launch()
        session.focus()
        session.prime_change_events()
        events.pump(1.0)

    separators = session.text().count("\n")
    assert separators > 0, "the snapshot should have one line per row"

    whole = [e for e in events.inserts() if (e["data"] or "").count("\n") >= separators]
    assert not whole, (
        f"an insert spans all {separators} row separators, re-announcing text "
        f"the client had already read:\n{events.summary()}"
    )
    assert events.inserts(), (
        f"typing produced no insert at all, so this proved nothing:\n{events.summary()}"
    )
