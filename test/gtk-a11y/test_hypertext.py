"""GtkAccessibleHypertext — OSC 8 and regex-matched links.

Orca announces links inline by reading this interface directly
(`_adjust_for_links` in its speech presenter); there are no link-role
children to find. Two past crashes live here: an unparented hyperlink whose
AT context never realized (SIGABRT inside Orca's D-Bus unmarshalling), and
an out-of-bounds `GetLink` racing a link-count decrease.
"""

from __future__ import annotations

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

import harness  # noqa: E402


def links(session):
    count = Atspi.Hypertext.get_n_links(session.terminal)
    return [
        harness.as_hyperlink(Atspi.Hypertext.get_link(session.terminal, i))
        for i in range(count)
    ]


def uris(session):
    return {Atspi.Hyperlink.get_uri(link, 0) for link in links(session)}


def test_osc8_link_is_exposed(session):
    assert harness.LINK_URI in uris(session), (
        f"OSC 8 link missing; got {sorted(uris(session))}"
    )


def test_regex_matched_url_is_exposed(session):
    """A bare URL in the output is matched by the configured `link-url` regex."""
    assert harness.BARE_URL in uris(session), (
        f"regex-matched URL missing; got {sorted(uris(session))}"
    )


def test_osc8_link_brackets_its_label(session):
    """Link offsets must cover exactly the label, in codepoints."""
    text = session.text()
    label_start = text.index(harness.LINK_LABEL)
    label_end = label_start + len(harness.LINK_LABEL)

    matches = [
        link
        for link in links(session)
        if Atspi.Hyperlink.get_uri(link, 0) == harness.LINK_URI
    ]
    assert matches, "OSC 8 link not found"
    link = matches[0]

    assert Atspi.Hyperlink.get_start_index(link) == label_start
    assert Atspi.Hyperlink.get_end_index(link) == label_end
    assert (
        Atspi.Text.get_text(session.terminal, label_start, label_end)
        == harness.LINK_LABEL
    )


def test_link_object_is_realized(session):
    """Resolving a link's anchor object must not crash the bridge.

    Each hyperlink's AT context has to be realized (and parented) before
    `get_link` returns it — GTK reads the D-Bus ref immediately afterwards,
    and an unrealized context yields an empty bus name that aborts the
    client inside `_atspi_dbus_return_hyperlink_from_iter`.

    Deliberately does not check `get_n_anchors`: GTK 4.22 publishes the
    Hyperlink `NAnchors` property as a D-Bus int16 while AT-SPI declares it
    int32, so at-spi2's client rejects the value and returns -1 for every
    GtkAccessibleHyperlink. That is a GTK bug, not a Ghostty one, and Orca
    does not read the property — it goes straight to `get_object`.
    """
    for link in links(session):
        anchor = Atspi.Hyperlink.get_object(link, 0)
        assert anchor is not None
        assert Atspi.Hyperlink.is_valid(link)


def test_link_index_at_offset(session):
    """An offset inside the label resolves to that link; outside, it doesn't."""
    text = session.text()
    inside = text.index(harness.LINK_LABEL) + 1
    index = Atspi.Hypertext.get_link_index(session.terminal, inside)
    assert index >= 0
    link = harness.as_hyperlink(Atspi.Hypertext.get_link(session.terminal, index))
    assert Atspi.Hyperlink.get_uri(link, 0) == harness.LINK_URI

    outside = text.index("alpha beta gamma")
    assert Atspi.Hypertext.get_link_index(session.terminal, outside) == -1


def test_out_of_bounds_get_link_returns_an_inert_sentinel(session):
    """Orca queues `GetLink(i)` after `GetNLinks` and the set can shrink.

    The AT-SPI contract says the index must be in range, but in practice a
    scroll or TUI redraw between the two calls breaks it. Reading past the
    end used to hand GTK garbage that it dereferenced unchecked. We return a
    persistent empty-range sentinel instead; it must survive being queried
    and must not overlap any real text, or Orca's
    `get_all_links_in_range` filter would splice a spurious " link" token
    into the start of a line.
    """
    count = Atspi.Hypertext.get_n_links(session.terminal)
    raw = Atspi.Hypertext.get_link(session.terminal, count + 500)
    assert raw is not None, "out-of-bounds GetLink returned nothing"
    sentinel = harness.as_hyperlink(raw)

    start = Atspi.Hyperlink.get_start_index(sentinel)
    end = Atspi.Hyperlink.get_end_index(sentinel)
    assert start == end, f"sentinel must be an empty range, got [{start}, {end})"

    text_length = len(session.text())
    assert not (0 <= start < text_length), (
        f"sentinel offset {start} falls inside the text (length {text_length}); "
        f"Orca would announce a phantom link"
    )


def test_repeated_queries_are_stable(session):
    """The link set is reused across refreshes, not rebuilt.

    Rebuilding invalidated the GObjects an AT client was still holding.
    """
    before = [
        (
            Atspi.Hyperlink.get_uri(link, 0),
            Atspi.Hyperlink.get_start_index(link),
            Atspi.Hyperlink.get_end_index(link),
        )
        for link in links(session)
    ]
    after = [
        (
            Atspi.Hyperlink.get_uri(link, 0),
            Atspi.Hyperlink.get_start_index(link),
            Atspi.Hyperlink.get_end_index(link),
        )
        for link in links(session)
    ]
    assert before == after
