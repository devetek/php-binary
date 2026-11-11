#!/usr/bin/env python3
"""Print the GitHub Actions build matrix as JSON.

The PHP versions are the newest patch release of each supported branch on
php.net, or the versions given in PHP_VERSIONS (space separated). With
PULL_REQUEST=1 it plans one build per CPU on Ubuntu 24.04. With
SKIP_RELEASED=1 a version whose release (php-X.Y.Z) already exists is left
out, so the daily run only builds new patch releases.
"""
import json
import os
import subprocess
import urllib.request

BRANCHES = ["8.1", "8.2", "8.3", "8.4", "8.5"]
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
    requested = requested or [latest(BRANCHES[-1])]
    TARGETS = [{"image": "ubuntu:24.04"}]
versions = requested or [latest(branch) for branch in BRANCHES]
if os.environ.get("SKIP_RELEASED") == "1":
    versions = [v for v in versions if not released(v)]

include = [
    {"php": php, "target": target["image"].replace(":", "-"), **target, **runner}
    for php in versions
    for target in TARGETS
    for runner in RUNNERS
]
print(json.dumps({"versions": versions, "matrix": {"include": include}}))
