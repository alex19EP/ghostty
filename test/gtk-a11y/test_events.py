"""Live behaviour: change events, the caret, and selection.

This module is the reason the harness exists. Everything here needs a real
terminal attached to a real pty producing real frames — none of it can be
reached from a unit test.

The tests type into the terminal, so they mutate the viewport. The module
gets its own Ghostty instance (the `session` fixture is module-scoped) and
the assertions only look at the row `cat` is echoing on.
"""

from __future__ import annotations

import gi
import pytest

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

import harness  # noqa: E402


@pytest.fixture(scope="module", autouse=True)
def primed(session):
    """Absorb the one-off full-viewport announcement before any test runs."""
    session.prime_change_events()


def test_typing_emits_one_small_insert(session):
    """A keystroke must produce a single-character insert.

    This is the assertion that justifies the whole per-frame diff. If
    `axNotifyIfChanged` ever regresses into re-announcing the viewport, Orca
    reads the entire screen back on every keypress and the terminal becomes
    unusable — but every unit test still passes, because the *text* is
    correct. Only an AT client can see the difference.
    """
    with harness.Events("object:text-changed") as events:
        session.type_text("z")
        events.pump(1.5)

    inserts = events.inserts()
    assert len(inserts) == 1, (
        f"expected exactly one insert for one keystroke, got "
        f"{len(inserts)}:\n{events.summary()}"
    )
    insert = inserts[0]
    assert insert["detail2"] == 1, (
        f"insert covered {insert['detail2']} characters, expected 1 — the "
        f"diff is re-announcing more than what changed:\n{events.summary()}"
    )
    assert insert["data"] == "z", f"inserted text was {insert['data']!r}"
    assert not events.deletes(), (
        f"an append should not delete anything:\n{events.summary()}"
    )


def test_typing_does_not_rewrite_the_viewport(session):
    """Total churn per keystroke stays proportional to what changed."""
    text_length = len(session.text())

    with harness.Events("object:text-changed") as events:
        session.type_text("abc")
        events.pump(2.0)

    assert events.inserts(), f"no insert events at all:\n{events.summary()}"
    churn = sum(record["detail2"] for record in events.records)
    assert churn <= 8, (
        f"{churn} characters churned for 3 keystrokes (viewport is "
        f"{text_length} characters):\n{events.summary()}"
    )
    assert "".join(record["data"] or "" for record in events.inserts()) == "abc"


def test_caret_advances_with_typing(session):
    """The reported caret follows the terminal cursor."""
    before = Atspi.Text.get_caret_offset(session.terminal)

    with harness.Events("object:text-caret-moved") as events:
        session.type_text("qq")
        events.pump(1.5)

    after = Atspi.Text.get_caret_offset(session.terminal)
    assert after == before + 2, f"caret went {before} -> {after}, expected +2"
    assert events.records, (
        "no caret-moved event; Orca tracks the cursor through these"
    )


def test_caret_is_inside_the_text(session):
    text = session.text()
    offset = Atspi.Text.get_caret_offset(session.terminal)
    assert 0 <= offset <= len(text)


def test_selection_round_trips(session):
    """Set a selection over a known word and read it back.

    `set_selection` maps codepoint offsets to terminal (row, col) pins and
    `get_selection` maps them back, so a range inside one row must survive
    the round trip exactly.
    """
    text = session.text()
    start = text.index("beta")
    end = start + len("beta")

    assert Atspi.Text.set_selection(session.terminal, 0, start, end) or (
        Atspi.Text.add_selection(session.terminal, start, end)
    ), "neither SetSelection nor AddSelection was accepted"

    assert Atspi.Text.get_n_selections(session.terminal) == 1
    selection = Atspi.Text.get_selection(session.terminal, 0)
    assert (selection.start_offset, selection.end_offset) == (start, end)
    assert (
        Atspi.Text.get_text(session.terminal, selection.start_offset, selection.end_offset)
        == "beta"
    )


def test_selection_can_be_cleared(session):
    text = session.text()
    start = text.index("gamma")
    Atspi.Text.set_selection(session.terminal, 0, start, start + 5)
    assert Atspi.Text.get_n_selections(session.terminal) == 1

    Atspi.Text.remove_selection(session.terminal, 0)
    assert Atspi.Text.get_n_selections(session.terminal) == 0


def test_set_caret_position_is_accepted(session):
    """GTK 4.22 `set_caret_position`, synthesized as a click.

    The pty here is `cat`, which has no shell integration, so the cursor
    does not actually move — a raw terminal sees a benign click. What we
    *can* assert without a shell is that our vfunc ran: the GTK bridge
    returns whatever `set_caret_position` returned (`gtkatspitext.c`
    `SetCaretOffset`), and GTK's default implementation returns FALSE. So a
    False here means the vfunc was never installed — which is how a braille
    display's cursor-routing keys go silently dead in Orca.
    """
    offset = session.offset_of("gamma")
    assert Atspi.Text.set_caret_offset(session.terminal, offset), (
        "SetCaretOffset returned FALSE: the set_caret_position vfunc is not "
        "installed, so Orca braille cursor routing does nothing"
    )
    assert 0 <= Atspi.Text.get_caret_offset(session.terminal) <= len(session.text())
