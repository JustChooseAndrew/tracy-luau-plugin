"""Copies the Tracy module from a Tracy-Luau checkout into the plugin, which inserts
and updates it in places.

    python tools/sync_module.py [PATH_TO_TRACY_LUAU]     (default: ../Tracy-Lua)
"""
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
source = os.path.join(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "Tracy-Lua"), "src", "Tracy")
target = os.path.join(HERE, "src", "TracyModule")

if not os.path.isfile(os.path.join(source, "init.luau")):
    raise SystemExit("no Tracy module at " + source)
shutil.rmtree(target, ignore_errors=True)
os.makedirs(target)
for name in sorted(os.listdir(source)):
    if name.endswith(".luau"):
        shutil.copyfile(os.path.join(source, name), os.path.join(target, name))
version = re.search(r'local VERSION = "([\d.]+)"', open(os.path.join(target, "init.luau"), encoding="utf-8").read())
print("copied Tracy %s from %s" % (version.group(1) if version else "?", os.path.abspath(source)))
