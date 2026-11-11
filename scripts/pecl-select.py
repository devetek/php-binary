#!/usr/bin/env python3
"""Print "name version" for each PECL extension to build for one PHP version.

Usage: pecl-select.py <pecl-extensions.txt> <php version>
"""
import sys


def branch(value):
    return tuple(int(part) for part in value.split(".")[:2])


path, php = sys.argv[1], branch(sys.argv[2])
chosen = {}
order = []
for line in open(path):
    fields = line.split("#", 1)[0].split()
    if not fields:
        continue
    name, version = fields[0], fields[1]
    since = branch(fields[2]) if len(fields) > 2 else (0, 0)
    if since > php:
        continue
    if name not in chosen:
        order.append(name)
    if name not in chosen or since >= chosen[name][0]:
        chosen[name] = (since, version)
for name in order:
    print(name, chosen[name][1])
