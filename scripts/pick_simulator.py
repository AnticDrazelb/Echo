"""Reads `xcrun simctl list devices available -j` from stdin and prints the
UDID of the newest available iPhone simulator."""
import json
import re
import sys

data = json.load(sys.stdin)
best = None
for runtime, devices in data.get("devices", {}).items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            key = (version, "Pro" in d["name"], d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"])
if best is None:
    sys.exit("No available iPhone simulator found")
print(best[1])
