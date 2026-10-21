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
sys.exit(launcher.main())
