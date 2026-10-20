"""What focus does to the two paths an AT client uses.

Change events (`object:text-changed`) are pushed from the render callback.
On-demand reads (flat review, caret and text queries) go through the
GtkAccessibleText vfuncs. Neither is gated on focus any more, but the two
have different failure modes and must not be confused: a surface can be
silent and still answer correctly when asked, which is what makes a lost
push path so easy to miss.

The invariant these tests defend is *recovery*. A surface that stops
announcing when it loses focus and never starts again is silent for the rest
of its life, and every unit test still passes, because the text is right —
only a client watching over time can tell. That is the same class of bug as
the viewport re-announcement in test_scroll.py, and it is why these assert
over a focus round trip rather than a single state.

Deliberately not asserted: how much an unfocused surface emits. That is
policy rather than a requirement — it was nothing while `glareaRender` had a
focus gate and is now the same as any other surface — and pinning it here
would make a deliberate change look like a regression. The tests report what
they saw instead.
"""

from __future__ import annotations

import subprocess
import time

import pytest

import harness


# A pty that produces output on its own, so focus is the only variable. Typing
# would not do: xdotool sends keystrokes to whichever window holds focus, which
# is precisely what these tests are moving around.
TICKER_SEED = f"""#!/bin/sh
printf '%s\\n' '{harness.READY_MARKER}'
i=0
while true; do
    printf 'tick %04d\\n' "$i"
    i=$((i + 1))
    sleep 1
done
"""

# The ticker emits once a second; four seconds of listening is comfortably
# more than one tick even if a frame is late.
LISTEN = 4.0


def count_events(label: str) -> int:
    with harness.Events("object:text-changed") as events:
        events.pump(LISTEN)
    print(f"  {label}: {len(events.records)} events")
    return len(events.records)


@pytest.fixture(scope="module")
def ticker(launch):
    live = launch(seed=TICKER_SEED)
    live.wait_for_text(lambda text: "tick 0002" in text, "the ticker to start")
    return live


def test_focused_surface_announces_output(ticker):
    assert count_events("focused") > 0, (
        "a focused surface produced no change events for a pty printing once a "
        "second — nothing downstream of this file can work if this fails"
    )


def test_surface_recovers_after_a_focus_round_trip(ticker, launch):
    """Lose focus to another window, take it back, and keep announcing.

    The failure this exists for is a one-way gate: something clears the
    surface's focus state and nothing ever sets it again, so the terminal goes
    quiet permanently. Recovering here is what proves the gate is a gate and
    not a latch.
    """
    print("\n--- focus round trip ---")
    before = count_events("focused  ")
    assert before > 0, "not announcing even before the round trip"

    # A second Ghostty takes the X input focus away.
    other = launch(seed=TICKER_SEED)
    try:
        time.sleep(1.0)
        focus_elsewhere = subprocess.run(
            ["xdotool", "getwindowfocus"], capture_output=True, text=True
        ).stdout.strip()
        assert focus_elsewhere != ticker._window_id, (
            "the second window never took focus, so this test proved nothing"
        )

        during = count_events("unfocused")
        readable = ticker.text()

        ticker.focus()
        time.sleep(1.0)
        assert (
            subprocess.run(
                ["xdotool", "getwindowfocus"], capture_output=True, text=True
            ).stdout.strip()
            == ticker._window_id
        ), "focus did not come back to the surface under test"

        after = count_events("refocused")
    finally:
        other.stop()

    assert "tick" in readable, (
        "an unfocused surface stopped answering on-demand reads; flat review "
        "and caret queries must not depend on focus"
    )
    assert after > 0, (
        f"the surface announced {before} events while focused, {during} while "
        f"unfocused, and {after} after regaining focus — it never started "
        f"again, so any focus glitch silences the terminal permanently"
    )
