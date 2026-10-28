#!/usr/bin/env python3
"""Verify a signed Universal app contains this build's two Mach-O UUIDs."""
import hashlib
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def uuids(path):
    output = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(path)], text=True)
    values = dict((arch, value.upper()) for value, arch in re.findall(r"UUID: ([0-9a-fA-F-]+) \(([^)]+)\)", output))
    if not values:
        raise SystemExit("No Mach-O build UUID found: " + str(path))
    return values


app = Path(sys.argv[1]).resolve()
executable = app / "Contents/MacOS/CodeFlight"
expected = {}
sources = {}
for arch, argument in zip(("arm64", "x86_64"), sys.argv[2:]):
    source = Path(argument).resolve()
    values = uuids(source)
    if set(values) != {arch}:
        raise SystemExit("Unexpected source architecture: " + str(source))
    expected[arch] = values[arch]
    sources[arch] = {"path": str(source), "uuid": values[arch], "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}
if set(expected) != {"arm64", "x86_64"} or uuids(executable) != expected:
    raise SystemExit("Release app does not match the two current build artifacts")
with (app / "Contents/Info.plist").open("rb") as stream:
    metadata = plistlib.load(stream)
print(json.dumps({"version": metadata["CFBundleShortVersionString"], "build": metadata["CFBundleVersion"], "sources": sources,
                  "appSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(), "verifiedUUIDs": expected}, indent=2))
