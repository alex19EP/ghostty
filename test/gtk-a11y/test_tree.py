"""The shape of the accessible tree we present to assistive technology.

Every assertion here corresponds to a bug that made Ghostty unusable with
Orca at some point: the wrong role, an unnamed application, or a tree
cluttered with implementation-detail widgets.
"""

from __future__ import annotations

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

import harness  # noqa: E402


def test_application_is_named(session):
    """The app must be findable by name on the accessibility bus.

    The AT-SPI bridge reads `g_get_prgname()` for the application object's
    Name (gtkatspiroot.c). With no prgname it reports "Unnamed" and Orca
    cannot locate the app at all.

    Note this is the *X11* name: `winproto/x11.zig` overrides prgname with
    `x11-instance-name` to derive WM_CLASS, which wins over the "Ghostty"
    set in `Application.init`. On Wayland the name stays "Ghostty".
    """
    assert session.app.get_name() == harness.INSTANCE_NAME
    assert session.app.get_role() == Atspi.Role.APPLICATION


def test_toplevel_role_is_frame(session):
    """Orca's `frame_and_dialog` lookup only finds FRAME/WINDOW toplevels.

    `Window.new` passes `accessible-role` as a construct property because
    `gtk_widget_class_set_accessible_role` does not reach the AT context in
    time; when that regressed, the toplevel reported "filler" and flat
    review had no zones to navigate.
    """
    role = session.frame.get_role()
    assert role in (Atspi.Role.FRAME, Atspi.Role.WINDOW), (
        f"toplevel reported {session.frame.get_role_name()!r}; Orca needs "
        f"frame or window"
    )


def test_terminal_role(session):
    """The surface itself must be ROLE_TERMINAL, not a generic widget."""
    assert session.terminal.get_role() == Atspi.Role.TERMINAL


def test_terminal_is_a_leaf(session):
    """`get_first_accessible_child` is overridden to return NULL.

    GTK's default would walk the widget tree and expose the GLArea, the
    overlays and the template descendants. Those have no semantic value and
    make object navigation and flat review noisy.
    """
    assert session.terminal.get_child_count() == 0


def test_terminal_states(session):
    """States Orca checks before it will read or track a widget."""
    states = session.terminal.get_state_set()
    for state in (Atspi.StateType.SHOWING, Atspi.StateType.VISIBLE):
        assert states.contains(state), f"terminal is missing {state.value_nick}"


def test_exactly_one_terminal_in_the_tree(session):
    """Guards against a second surface accidentally becoming accessible."""
    terminals = [
        node
        for node in harness.walk(session.app)
        if node.get_role() == Atspi.Role.TERMINAL
    ]
    assert len(terminals) == 1, f"expected 1 terminal accessible, found {len(terminals)}"
