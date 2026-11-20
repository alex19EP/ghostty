"""Reading a surface GTK does not paint.

The accessible text is cached between frames, and every painted frame checks
the cache against the screen. A surface that is not painted, in a background
tab or a minimized window, gets no frames, so no frame ever checks it: without
a separate path its cache keeps whatever the screen held when it was hidden,
while the program behind it keeps printing. An AT client reading it would get
the old screen.

Xvfb has no window manager to minimize with, so the test unmaps the window
itself, which is what minimizing does to an X11 window.
"""

from __future__ import annotations

import subprocess
import time

import harness

HIDDEN_DONE = "LATE-OUTPUT-WHILE-HIDDEN"

# Waits for a line on stdin, then prints a marker after a delay long enough
# for the test to hide the window first.
HIDDEN_SEED_SCRIPT = f"""#!/bin/sh
printf '%s\\n' '{harness.READY_MARKER}'
while read _cmd; do
    sleep 1.5
    printf '%s\\n' '{HIDDEN_DONE}'
done
"""


def test_hidden_surface_reads_the_current_screen(launch):
    session = launch(seed=HIDDEN_SEED_SCRIPT, instance="ghostty-a11y-test-hidden")
    session.focus()

    # The harness has read the text while starting up, so the surface has
    # a cache. Ask for the late output, then hide the window before it
    # arrives. Return goes as a key: typed as "\n" it does not end the
    # line `read` waits for.
    session.type_text("go")
    session.send_key("Return")
    subprocess.run(["xdotool", "windowunmap", session._window_id], check=True)

    # Let the output arrive while it is hidden, then read it.
    time.sleep(3.0)
    text = session.text()
    assert HIDDEN_DONE in text, (
        "the hidden surface still serves the screen from before it was "
        "hidden; its last rows:\n" + "\n".join(text.rstrip("\n").split("\n")[-5:])
    )
