#!/usr/bin/env python3
"""Make a PHP build carry its own shared libraries.

Usage: bundle-libs.py <prefix>

For legacy PHP (8.0 and older), built on an old OS because it needs
OpenSSL 1.x and old ICU: copies every library the build links to, except
glibc and the C/C++ runtime that newer systems provide compatibly, into
<prefix>/lib/bundled, and points each ELF file there with a relative rpath.
The build then runs on any newer Debian or Ubuntu without OS packages.
"""
import os
import shutil
import subprocess
import sys

# Provided by every target system, in a backward compatible version.
SYSTEM = (
    "linux-vdso", "ld-linux", "libc.so", "libm.so", "libdl.so", "libpthread.so",
    "librt.so", "libresolv.so", "libutil.so", "libcrypt.so", "libgcc_s.so",
    "libstdc++.so", "libanl.so", "libnss_",
)

prefix = os.path.realpath(sys.argv[1])
bundled = os.path.join(prefix, "lib", "bundled")
os.makedirs(bundled, exist_ok=True)


def elf_files(root):
    for directory, _, files in os.walk(root):
        for name in files:
            path = os.path.join(directory, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            with open(path, "rb") as handle:
                if handle.read(4) == b"\x7fELF":
                    yield path


def dependencies(path):
    out = subprocess.run(["ldd", path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True).stdout
    for line in out.splitlines():
        if "=> /" in line:
            library = line.split("=>", 1)[1].split("(", 1)[0].strip()
            if not os.path.basename(library).startswith(SYSTEM):
                yield library


copied = set()
for path in list(elf_files(prefix)):
    for library in dependencies(path):
        name = os.path.basename(library)
        if name in copied or os.path.realpath(library).startswith(prefix + os.sep):
            continue
        shutil.copy2(os.path.realpath(library), os.path.join(bundled, name))
        os.chmod(os.path.join(bundled, name), 0o755)
        copied.add(name)

for path in elf_files(prefix):
    relative = os.path.relpath(bundled, os.path.dirname(path))
    origin = "$ORIGIN" if relative == "." else "$ORIGIN/" + relative
    subprocess.run(["patchelf", "--force-rpath", "--set-rpath", origin, path], check=True)

print("bundled %d libraries: %s" % (len(copied), " ".join(sorted(copied))))
