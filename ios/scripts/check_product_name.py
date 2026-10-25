#!/usr/bin/env python3
"""Fails when text a person can read says "Slate" on its own instead of "Slate Pro".

The product is called Slate Pro. The working name "Slate" lives on in code nobody reads (the module, folders, the slate://
link scheme, bundle ids, storage keys, slate.example), so this only looks at string literals in the app and widget
sources, the permission messages and name in project.yml, and the notification wording in the Edge Functions.

    python3 ios/scripts/check_product_name.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BARE = re.compile(r"\bSlate\b(?! Pro)")
LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')
problems = []

for folder in ("Slate", "SlateWidgets", "Shared"):
    for path in sorted((ROOT / folder).rglob("*.swift")):
        for number, line in enumerate(path.read_text().split("\n"), 1):
            if line.lstrip().startswith("//"):
                continue
            for literal in LITERAL.findall(line):
                if BARE.search(literal):
                    problems.append(f"{path.relative_to(ROOT)}:{number}: {literal[:100]}")

project = ROOT / "project.yml"
for number, line in enumerate(project.read_text().split("\n"), 1):
    if re.match(r"\s*(CFBundleDisplayName|NS\w+UsageDescription):", line) and BARE.search(line.split(":", 1)[1]):
        problems.append(f"project.yml:{number}: {line.strip()[:100]}")

for path in sorted((ROOT / "supabase" / "functions").rglob("*.ts")):
    for number, line in enumerate(path.read_text().split("\n"), 1):
        if not line.lstrip().startswith("//") and BARE.search(re.sub(r"https?://\S+", "", line)):
            problems.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()[:100]}")

if problems:
    print('Say "Slate Pro", not "Slate", in anything a person reads:')
    for problem in problems:
        print("  ", problem)
    sys.exit(1)
print('Everything a person reads says "Slate Pro".')
