# GTK accessibility tests

Integration tests that drive a real Ghostty through AT-SPI, the way a screen
reader does. They exist to cover the part of the accessibility implementation
that unit tests structurally cannot reach: the D-Bus surface, the GTK vtables,
and the change events emitted while a terminal is live.

```sh
zig build -Dapp-runtime=gtk
test/gtk-a11y/run.sh
```

## Why these are not unit tests

Most of the accessibility logic already is unit tested — `src/apprt/a11y_text.zig`
and `src/apprt/a11y_offsets.zig` are deliberately GTK-free so `zig build test`
can cover the viewport walk and the offset math directly. Prefer adding tests
there; they are faster and run in CI.

What is left over needs a running application:

- **Vtable wiring.** Whether a `GtkAccessibleText` vfunc is actually reached
  depends on struct layouts agreeing with the GTK the binary is linked against.
  A mismatch compiles cleanly, passes every unit test, and silently disables the
  feature.
- **Event granularity.** That a keystroke produces a one-character
  `text-changed:insert` rather than a whole-viewport rewrite is invisible to
  unit tests — the resulting *text* is identical either way. Only a client
  receiving the events can tell, and the difference is the difference between a
  usable terminal and an unusable one.
- **D-Bus marshalling.** Offsets, ranges and object references cross a type
  boundary that only exists at runtime.

## Why these are not in CI

They need a display server, a session bus, an accessibility bus and software
GL, and they take seconds rather than milliseconds. Upstream already made this
call for the macOS UI tests: `macos/GhosttyUITests` overrides `defaultTestSuite`
to return nothing unless run from Xcode, "so that we don't have to wait for each
ci check to run these tedious tests". These follow the same pattern — `run.sh`
sets `GHOSTTY_A11Y_TEST=1`, and without it `conftest.py` skips everything, so a
bare `pytest` at the repo root stays green instead of erroring on a missing
display.

## Requirements

Beyond a built Ghostty: `Xvfb`, `dbus-run-session`, `gdbus`, `xdotool`,
`pytest`, python-gobject with the Atspi 2.0 typelib, and at-spi2-core. On Arch
that is `xorg-server-xvfb`, `xdotool`, `python-pytest`, `python-gobject` and
`at-spi2-core`. `run.sh` checks for all of them and names what is missing.

`run.sh` creates a private X display, a private session bus and a private
accessibility bus, so a run never touches your desktop or the accessibility bus
your screen reader is on. Ghostty gets a throwaway `XDG_CONFIG_HOME` too — your
own config is not read.

## Layout

| File | Contents |
| --- | --- |
| `run.sh` | Environment setup and the opt-in gate. Takes pytest arguments. |
| `harness.py` | Launching Ghostty, finding it on the bus, typing, collecting events. |
| `conftest.py` | The `session` fixture (one Ghostty per test module) and the `launch` factory behind it. |
| `test_tree.py` | Roles, application name, and the shape of the accessible tree. |
| `test_text.py` | `GtkAccessibleText`: contents, codepoint offsets, extents, attributes. |
| `test_hypertext.py` | OSC 8 and regex links, and the out-of-bounds sentinel. |
| `test_events.py` | Change events, the caret, and selection — needs a live pty. |
| `test_click.py` | Braille cursor routing: that the synthetic click lands on the routed-to cell. Its pty has mouse reporting on. |

Each test module gets its own Ghostty instance, because `test_events.py` types
into the terminal and would otherwise leak state into the others.

## Writing tests

Assert what an assistive technology can observe, and say in the docstring which
failure the assertion is there to catch. Most of these correspond to a specific
bug that made Ghostty unusable with Orca; that context is what stops a future
reader from "simplifying" the assertion away.

Where a real client has to work around a quirk, work around it the same way and
say so — `harness.as_hyperlink` mirrors what Orca's `AXHypertext` does, so the
tests exercise the path that actually ships.

## Debugging

```sh
test/gtk-a11y/run.sh -k hypertext -x        # one area, stop on first failure
test/gtk-a11y/run.sh -s                     # let prints through
GHOSTTY_A11Y_KEEP=1 test/gtk-a11y/run.sh    # keep temp dirs and ghostty.log
GHOSTTY_BIN=/path/to/ghostty test/gtk-a11y/run.sh
```

On failure the `session` fixture reports Ghostty's own stderr, which is usually
where the answer is.
