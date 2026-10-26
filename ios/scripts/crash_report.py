"""Prints what a crash report says, for the CI log: the reason and the frames of the thread that crashed.

    python3 scripts/crash_report.py <file.ips>
"""
import json
import sys

raw = open(sys.argv[1]).read().split("\n", 1)
body = json.loads(raw[1]) if len(raw) > 1 else {}
for key in ("exception", "termination", "asi"):
    print(key, json.dumps(body.get(key))[:1500])
for thread in [t for t in body.get("threads", []) if t.get("triggered")][:1]:
    for frame in thread.get("frames", [])[:30]:
        print("  ", frame.get("symbol"), frame.get("sourceFile", ""), frame.get("sourceLine", ""))
