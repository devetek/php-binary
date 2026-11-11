#!/usr/bin/env python3
"""Print the GitHub Actions build matrix as JSON.

The PHP versions are the newest patch release of each supported branch on
php.net, or the versions given in PHP_VERSIONS (space separated). With
PULL_REQUEST=1 it plans the oldest and newest PHP, one build per CPU, on
Ubuntu 24.04 for modern PHP. With
SKIP_RELEASED=1 a version whose release (php-X.Y.Z) already exists is left
out, so the daily run only builds new patch releases.
"""
import json
import os
import subprocess
import urllib.request

BRANCHES = ["5.6", "7.3", "7.4", "8.0", "8.1", "8.2", "8.3", "8.4", "8.5"]
# PHP 8.0 and older are built once per CPU on the OS that still has their
# libraries, then tested on every target OS (see scripts/bundle-libs.py).
LEGACY = {"5.6": "ubuntu:16.04", "7.3": "ubuntu:18.04", "7.4": "ubuntu:18.04", "8.0": "ubuntu:18.04"}
TARGETS = [
    {"image": "ubuntu:22.04"},
    {"image": "ubuntu:24.04"},
    {"image": "ubuntu:26.04"},
    {"image": "debian:12"},
    {"image": "debian:13"},
]
RUNNERS = [
    {"runner": "ubuntu-24.04", "arch": "amd64"},
    {"runner": "ubuntu-24.04-arm", "arch": "arm64"},
]


def latest(branch):
    url = f"https://www.php.net/releases/?json&version={branch}"
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)["version"]


def released(version):
    result = subprocess.run(
        ["gh", "release", "view", f"php-{version}", "--json", "tagName"],
        capture_output=True,
    )
    return result.returncode == 0


requested = os.environ.get("PHP_VERSIONS", "").split()
if os.environ.get("PULL_REQUEST") == "1":
    # A pull request checks the scripts with one build per CPU.
    # The newest PHP, and the oldest to cover the legacy build.
    requested = requested or [latest(BRANCHES[0]), latest(BRANCHES[-1])]
    TARGETS = [{"image": "ubuntu:24.04"}]
versions = requested or [latest(branch) for branch in BRANCHES]
if os.environ.get("SKIP_RELEASED") == "1":
    versions = [v for v in versions if not released(v)]

SMOKE = " ".join(target["image"] for target in TARGETS)
include = []
for php in versions:
    branch = ".".join(php.split(".")[:2])
    for runner in RUNNERS:
        if branch in LEGACY:
            include.append({"php": php, "target": "linux", "image": LEGACY[branch], "smoke": SMOKE, **runner})
            continue
        for target in TARGETS:
            include.append({"php": php, "target": target["image"].replace(":", "-"), "smoke": target["image"], **target, **runner})
print(json.dumps({"versions": versions, "matrix": {"include": include}}))
