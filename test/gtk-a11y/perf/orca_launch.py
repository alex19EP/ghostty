"""Start Orca without its "another Orca is running" check.

/usr/bin/orca refuses to start while any process of this uid is called
`orca` — which the user's real screen reader on their real desktop is. This
instance lives on a private display, session bus and a11y bus, so the two
never meet. Never pass --replace: that SIGKILLs every other Orca of this uid.
"""

import importlib.machinery
import importlib.util
import os
import sys

assert "--replace" not in sys.argv and "-r" not in sys.argv
# ORCA_ROOT: an install prefix (bin/orca, lib/python3.X/site-packages) to
# run instead of the system Orca. Its site-packages goes first on sys.path;
# the launcher's own insert(1, ...) of its configured prefix lands after it.
root = os.environ.get("ORCA_ROOT")
launcher_path = "/usr/bin/orca"
if root:
    sys.path.insert(0, os.path.join(root, "lib", f"python{sys.version_info[0]}.{sys.version_info[1]}", "site-packages"))
    launcher_path = os.path.join(root, "bin", "orca")
loader = importlib.machinery.SourceFileLoader("orca_launcher", launcher_path)
spec = importlib.util.spec_from_loader("orca_launcher", loader)
launcher = importlib.util.module_from_spec(spec)
loader.exec_module(launcher)
launcher.other_orcas = lambda: []
import orca  # noqa: E402

print(f"orca package: {orca.__file__}", flush=True)

# ORCA_NO_BRAILLE=1: braille/enabled = false in the default profile. Orca has
# no command line switch for it, and run.sh's memory GSettings backend lives
# in this process, so it has to be set here before Orca reads it.
if os.environ.get("ORCA_NO_BRAILLE"):
    from gi.repository import Gio  # noqa: E402

    Gio.Settings.new_with_path("org.gnome.Orca.Braille", "/org/gnome/orca/default/braille/").set_boolean(
        "enabled", False
    )
    print("braille disabled", flush=True)

# ORCA_LINK_STACKS=1: write the Python stack of every call to Orca's
# link-walking helpers into its debug log (--orca-debug), as "LINK STACK:".
if os.environ.get("ORCA_LINK_STACKS"):
    import traceback  # noqa: E402

    from orca import debug  # noqa: E402
    from orca.ax_utilities import AXUtilities  # noqa: E402
    from orca.ax_utilities_hypertext import AXUtilitiesHypertext  # noqa: E402

    def _traced(name, func):
        def wrapper(*args, **kwargs):
            stack = "".join(traceback.format_stack()[:-1])
            debug.print_message(debug.LEVEL_INFO, f"LINK STACK: {name}\n{stack}", True)
            return func(*args, **kwargs)

        return staticmethod(wrapper)

    # AXUtilities copies the helpers at import time, so patch both classes.
    for name in ("get_all_links_in_range", "get_all_links"):
        traced = _traced(name, getattr(AXUtilitiesHypertext, name))
        setattr(AXUtilitiesHypertext, name, traced)
        setattr(AXUtilities, name, traced)

sys.exit(launcher.main())
