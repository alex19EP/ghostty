"""Activating a link from the keyboard.

Links have been *announced* to screen readers on this branch for a while —
`test_hypertext.py` covers that. Announcing something the user cannot reach is
only half a feature, so this covers the other half: putting the cursor on a
link and pressing a key to open it.

Opening genuinely launches a browser, which a test cannot observe and should
not trigger. What it can observe is the part that is actually new: whether a
link is found under the cursor at all. `open_link` is declared `performable`
in the harness config, so the answer shows up in the viewport — a hit consumes
the keypress, a miss falls through and lets `cat` echo F6's escape sequence as
literal text. The opening itself is shared with mouse clicks
(`Surface.openLink`), which is why it is not retested here.

Each test gets its own session because the cursor is parked with a CUP escape
baked into the seed. It cannot be moved afterwards: the pty runs in canonical
mode with ECHOCTL, so an escape typed into `cat` comes back as the two
characters `^[` rather than a control sequence the terminal would act on.
That same property is what makes the echo probe below reliable.
"""

from __future__ import annotations

import time

import gi
import pytest

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

import harness  # noqa: E402


def seed_with_cursor_at(row: int, col: int) -> str:
    """Three rows — an OSC 8 link, a bare URL, plain text — cursor parked.

    `row` and `col` are 1-based, as the CUP escape expects.
    """
    return f"""#!/bin/sh
printf '\\033]8;;{harness.LINK_URI}\\033\\\\{harness.LINK_LABEL}\\033]8;;\\033\\\\\\n'
printf 'see {harness.BARE_URL} here\\n'
printf 'plain text with no link\\n'
printf '%s\\n' '{harness.READY_MARKER}'
printf '\\033[{row};{col}H'
exec cat
"""


# Where an unconsumed keypress lands. ECHOCTL renders ESC as `^[`.
ECHO_MARKER = "^["


def found_a_link(session) -> bool:
    """Press F6 and report whether the binding claimed a link."""
    before = session.text().count(ECHO_MARKER)
    session.send_key("F6")
    time.sleep(0.6)
    after = session.text().count(ECHO_MARKER)
    return after == before


@pytest.fixture
def at(launch):
    """Launch a session with the cursor parked at (row, col)."""

    def _at(row: int, col: int):
        live = launch(seed_with_cursor_at(row, col))
        live.focus()
        return live

    return _at


def test_no_link_under_the_cursor_falls_through(at):
    """Baseline, and the half that proves the probe can detect a miss.

    Without it, a test asserting "consumed" could pass because the escape
    sequence never echoes for some unrelated reason, making every other
    assertion in this file vacuous.
    """
    session = at(3, 3)  # 'plain text with no link'
    assert not found_a_link(session), (
        "F6 was consumed on a row with no link — either open_link claims "
        "links that do not exist, or the echo probe is broken"
    )


def test_osc8_hyperlink_is_activated(at):
    """An OSC 8 hyperlink, the kind `test_hypertext.py` exposes to Orca.

    This must work with no modifier held. Clicking requires ctrl/super to
    disambiguate a link click from a text selection; a deliberate keypress
    carries no such ambiguity, which is why `linkAtPinForActivation` drops
    the modifier check that `linkAtPos` applies.
    """
    session = at(1, 3)  # inside LINK_LABEL
    assert found_a_link(session), (
        f"F6 fell through on the OSC 8 row: {harness.LINK_LABEL!r} is "
        f"announced to screen readers but cannot be activated"
    )


def test_configured_regex_link_is_activated(at):
    """A bare URL matched by the `link-url` regex rather than an OSC 8 escape."""
    session = at(2, 8)  # inside BARE_URL
    assert found_a_link(session), (
        f"F6 fell through on the bare URL row: {harness.BARE_URL!r} is "
        f"matched by the configured link regex and should activate"
    )
