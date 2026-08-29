"""The header bar's title label must survive AT-SPI extents queries mid-update.

GTK's `GtkLabel` implementation of `GtkAccessibleText.get_extents` (gtklabel.c,
identical in 4.22.4 and main) reads its cached `PangoLayout` *before* the call
that would rebuild it:

    layout = label->layout;                           /* NULL after set_text */
    gtk_label_get_layout_location (label, &lx, &ly);  /* this ensures it... */
    gdk_pango_layout_get_clip_region (layout, ...);   /* ...too late */

`gtk_label_set_text` clears the layout, and nothing rebuilds it until the next
frame measures the label. So an AT-SPI `GetCharacterExtents` /
`GetRangeExtents` that lands on a label between a text change and the next
frame dereferences NULL inside `cairo_region_get_extents` and takes the whole
process down. That is the crash reported against Ghostty on the Orca list
(2026-08-28): Codex and Claude Code rewrite the terminal title many times a
second, `window.blp` binds it straight into an `Adw.WindowTitle`, and Orca
asks every label in the window for extents while building a flat-review
context.

Ghostty cannot fix GTK, but it can close the window: `Window` connects to the
`Adw.WindowTitle`'s `notify::title` / `notify::subtitle` and calls
`gtk_label_get_layout()` on the labels inside, in the same call stack as the
text change. AT-SPI method calls are only dispatched from the main loop, so
with the layout rebuilt before the handler returns there is no moment at
which a client can observe it missing.

This module sits inside that race deliberately: the pty changes the title once
a millisecond for a few seconds while the test hammers the label with extents
queries. Without the workaround the debug build dies within the first few
hundred queries. The header bar is off in `CONFIG_TEMPLATE`, so this module
opts back in.
"""

from __future__ import annotations

import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib  # noqa: E402

import pytest  # noqa: E402

import harness  # noqa: E402

# The template turns the header bar off; the labels under test live in it.
TITLE_CONFIG = """
gtk-titlebar = true
window-decoration = client
"""

# How long to keep querying. The pty's storm lasts a little longer than this
# (TITLE_SPINS x ~1.3 ms), so the queries never outlive the title changes.
STORM_SECONDS = 3.0


@pytest.fixture(scope="module")
def session(launch):
    return launch(seed=harness.TITLE_SEED_SCRIPT, config=TITLE_CONFIG)


def _title_label(session) -> Atspi.Accessible | None:
    """The header bar label currently showing the marker title.

    Matched by accessible name: `gtk_label_set_text` mirrors the text into the
    label's accessible-name property, which is also why Orca announces title
    changes at all.
    """
    for node in harness.walk(session.frame):
        if node.get_role() != Atspi.Role.LABEL:
            continue
        if node.get_name() == harness.TITLE_MARKER:
            return node
    return None


def _wait_for_label(session) -> Atspi.Accessible:
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        label = _title_label(session)
        if label is not None:
            return label
        time.sleep(0.05)
    raise AssertionError(
        "no LABEL named "
        f"{harness.TITLE_MARKER!r} under the toplevel; is the header bar visible?"
    )


def test_title_label_is_exposed(session):
    """The title label is in the tree and implements the Text interface.

    Both are preconditions for the crash: a label Orca cannot see would never
    be asked for extents.
    """
    label = _wait_for_label(session)
    assert Atspi.Text.get_text(label, 0, -1) == harness.TITLE_MARKER

    # Mapped and allocated, i.e. something flat review would include.
    box = Atspi.Component.get_extents(label, Atspi.CoordType.WINDOW)
    assert box.width > 0 and box.height > 0, "title label has no allocation"

    # `GetCharacterExtents` is useless on a GtkLabel — GTK hands the vfunc an
    # empty (offset, offset) range and gets an empty region back — so the
    # storm below uses a one-character `GetRangeExtents` instead. Check here
    # that it reaches the same vfunc and yields a real rect.
    rect = Atspi.Text.get_range_extents(label, 0, 2, Atspi.CoordType.WINDOW)
    assert rect.width > 0 and rect.height > 0, "range extents came back empty"


def test_extents_survive_a_title_storm(session):
    """Query the label's extents continuously while its text churns.

    Every query is a synchronous D-Bus round trip dispatched on Ghostty's
    main loop between title updates — exactly where the stale-layout read
    happens. The assertions are that the process is still alive afterwards,
    that the queries kept succeeding, and that the title stream itself was
    not broken by the workaround (the marker comes back at the end).
    """
    label = _wait_for_label(session)

    session.send_key("Return")

    calls = 0
    deadline = time.monotonic() + STORM_SECONDS
    while time.monotonic() < deadline:
        assert session.proc.poll() is None, (
            f"Ghostty exited with {session.proc.returncode} after {calls} "
            f"extents queries\n\n--- ghostty output ---\n{session.diagnostics()}"
        )
        try:
            # Offsets 0..2 stay inside every title the storm produces
            # ("spin N" is six characters at its shortest); reading past the
            # end would be a different GTK bug and not the one under test.
            Atspi.Text.get_range_extents(label, 0, 2, Atspi.CoordType.WINDOW)
        except GLib.Error as err:
            if session.proc.poll() is not None:
                raise AssertionError(
                    f"Ghostty exited with {session.proc.returncode} during an "
                    f"extents query ({err}) after {calls} queries\n\n"
                    f"--- ghostty output ---\n{session.diagnostics()}"
                ) from err
            raise
        calls += 1

    assert session.proc.poll() is None, (
        f"Ghostty exited with {session.proc.returncode} after the storm\n\n"
        f"--- ghostty output ---\n{session.diagnostics()}"
    )
    # A few hundred per second is the floor even on a loaded box; the point
    # is that the loop actually ran inside the storm, not merely once.
    assert calls > 300, f"only {calls} extents queries in {STORM_SECONDS}s"

    session.wait_for_text(
        lambda text: harness.TITLE_SPIN_DONE in text, "the title storm to finish"
    )
    deadline = time.monotonic() + 5.0
    while label.get_name() != harness.TITLE_MARKER and time.monotonic() < deadline:
        time.sleep(0.05)
    assert label.get_name() == harness.TITLE_MARKER, (
        f"title label reads {label.get_name()!r} after the storm; the title "
        "stream did not come back to the marker"
    )
