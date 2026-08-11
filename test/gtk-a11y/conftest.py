"""pytest wiring for the GTK accessibility tests.

These tests are opt-in. They need a display, a session bus and an accessibility
bus, they launch a real Ghostty, and they take seconds rather than milliseconds
— the same reasons upstream keeps `macos/GhosttyUITests` out of CI. `run.sh`
provides the environment and sets GHOSTTY_A11Y_TEST; without it we refuse to
collect rather than fail confusingly.
"""

from __future__ import annotations

import os

import pytest

import harness


def pytest_collection_modifyitems(config, items):
    if os.environ.get("GHOSTTY_A11Y_TEST") == "1":
        return
    skip = pytest.mark.skip(
        reason="GTK a11y tests are opt-in; run them via test/gtk-a11y/run.sh"
    )
    for item in items:
        item.add_marker(skip)


@pytest.fixture(scope="module")
def launch():
    """Factory for a running Ghostty, for modules that need their own pty.

    Most modules want the default seed and should use the `session` fixture.
    Take this one only when the test needs a different program behind the pty
    (test_click.py turns on mouse reporting), a different environment
    (test_scaling.py forces a HiDPI scale factor), or two terminals at once —
    in which case give each a distinct `instance` — and override `session`
    locally so the tests still read the same.
    """
    started = []

    def _launch(
        seed: str = harness.SEED_SCRIPT,
        instance: str = harness.INSTANCE_NAME,
        env: dict | None = None,
    ) -> harness.Session:
        import gi

        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi

        Atspi.init()

        live = harness.Session(seed=seed, instance=instance, env=env)
        started.append(live)
        try:
            live.start()
        except Exception as err:  # pragma: no cover - startup diagnostics
            pytest.fail(f"{err}\n\n--- ghostty output ---\n{live.diagnostics()}")
        return live

    yield _launch
    for live in started:
        live.stop()


@pytest.fixture(scope="module")
def session(launch):
    """A freshly launched Ghostty, one per test module.

    Per-module rather than per-session because some tests type into the
    terminal, and per-module rather than per-test because launching costs a
    second or two. Within a module, order-dependent tests say so explicitly.
    """
    return launch()
