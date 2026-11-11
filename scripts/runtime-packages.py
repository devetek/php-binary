#!/usr/bin/env python3
"""Print the OS packages that provide the shared libraries a PHP build uses.

Usage: runtime-packages.py <prefix>

Walks every ELF file under the prefix, asks ldd for the libraries outside the
prefix, and maps them to Debian packages with dpkg -S. Servers install these
packages, and no compiler, to run the build.
"""
import os
import subprocess
import sys

prefix = os.path.realpath(sys.argv[1])
libraries = set()
for root, _, files in os.walk(prefix):
    for name in files:
        path = os.path.join(root, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        with open(path, "rb") as handle:
            if handle.read(4) != b"\x7fELF":
                continue
        out = subprocess.run(["ldd", path], capture_output=True, text=True).stdout
        for line in out.splitlines():
            if "=> /" not in line:
                continue
            library = line.split("=>", 1)[1].split("(", 1)[0].strip()
            if not os.path.realpath(library).startswith(prefix + os.sep):
                libraries.add(library)

packages = set()
missing = []
for library in sorted(libraries):
    # dpkg records a file under one spelling; try the path ldd gave, the
    # resolved file, and the /usr-merged and unmerged forms of both.
    candidates = []
    for path in (library, os.path.realpath(library)):
        candidates += [path, path.replace("/usr/lib/", "/lib/", 1), path.replace("/lib/", "/usr/lib/", 1)]
    for candidate in dict.fromkeys(candidates):
        result = subprocess.run(["dpkg", "-S", candidate], capture_output=True, text=True)
        # Lines look like "pkg[, pkg2]: /path"; "diversion by …" lines are not owners.
        owners = [
            line.split(": ", 1)[0]
            for line in result.stdout.splitlines()
            if ": " in line and not line.startswith("diversion ")
        ]
        if result.returncode == 0 and owners:
            packages.update(name.strip().split(":", 1)[0] for name in owners[0].split(","))
            break
    else:
        missing.append(library)

for package in sorted(packages):
    print(package)
for library in missing:
    print(f"warning: no package owns {library}", file=sys.stderr)
