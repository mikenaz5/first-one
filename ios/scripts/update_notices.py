#!/usr/bin/env python3
"""Writes Slate/Resources/ThirdPartyNotices.txt: the licence text of every code package and font file the app carries.

The app shows that file under Settings > About > Open-source licences. Most open-source licences (MIT, Apache 2.0, BSD) allow
use in an app on one condition: the copyright notice and the licence text travel with it. This is how they do.

    python3 scripts/update_notices.py                        the packages named in project.yml, and the bundled fonts
    python3 scripts/update_notices.py --resolved Package.resolved   everything the build resolved, with the exact versions

The bundled fonts (Slate/Resources/Fonts, used only for the contract PDF) are listed in FONTS below: add a line there when a
font file is added, with the repository and the release tag its files came from.

It reads the licence from each package's own GitHub repository (the file called LICENSE at the version that was built, or the
newest if that tag can't be found) and stops with a message when it can't find one, so a package never goes in unlicensed.
`scripts/check_assets.py --resolved` (CI) fails when a resolved package has no notice.
"""
import json
import pathlib
import re
import sys
import urllib.error
import urllib.request

IOS = pathlib.Path(__file__).resolve().parent.parent
OUT = IOS / "Slate" / "Resources" / "ThirdPartyNotices.txt"
NAMES = ["LICENSE", "LICENSE.md", "LICENSE.txt", "License.md", "license.md", "LICENSE.TXT", "COPYING", "OFL.txt"]
# Font families carried in Slate/Resources/Fonts: (name, repository, release the files came from). Their licence is the SIL Open
# Font License 1.1, which allows bundling in an app and embedding in documents as long as the notice travels with them.
FONTS = [
    ("Inter", "https://github.com/rsms/inter", "4.0"),
    ("JetBrains Mono", "https://github.com/JetBrains/JetBrainsMono", "2.304"),
]
HEADER = """Slate Pro is built with the open-source code and fonts listed below. Each is used under its own licence, whose text is
reproduced here as that licence asks. Thank you to the people who wrote them.

"""


def fetch(url: str) -> str | None:
    try:
        with urllib.request.urlopen(url, timeout=30) as reply:
            return reply.read().decode("utf-8", "replace")
    except (urllib.error.URLError, TimeoutError):
        return None


def licence_for(repo_url: str, version: str | None) -> tuple[str, str, str] | None:
    match = re.match(r"https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", repo_url)
    if not match:
        return None
    owner, repo = match.groups()
    refs = [r for r in ([version, f"v{version}"] if version and re.match(r"^\d", version) else [version] if version else [])]
    refs += ["HEAD"]
    for ref in refs:
        for name in NAMES:
            text = fetch(f"https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{name}")
            if text and len(text.strip()) > 200:
                return text.strip(), f"{owner}/{repo} at {ref}, file {name}", f"https://raw.githubusercontent.com/{owner}/{repo}/{ref}/"
    return None


def notice_for(base: str) -> str | None:
    """The NOTICE file some Apache-licensed packages carry. Apache License 2.0 section 4(d) asks that its text travels too."""
    for name in ("NOTICE", "NOTICE.txt", "NOTICE.md"):
        text = fetch(base + name)
        if text and len(text.strip()) > 40:
            return text.strip()
    return None


def kind(text: str) -> str:
    low = text.lower()
    if "sil open font license" in low:
        return "SIL Open Font License 1.1"
    if "apache license" in low:
        return "Apache License 2.0"
    if "mit license" in low or "permission is hereby granted, free of charge" in low:
        return "MIT License"
    if "redistribution and use in source and binary forms" in low:
        return "BSD licence"
    return "see the text"


def packages_from_project() -> list[tuple[str, str, str | None]]:
    found = []
    for url in re.findall(r"^\s+url:\s*(\S+)", (IOS / "project.yml").read_text(encoding="utf-8"), re.M):
        found.append((url.rstrip("/").removesuffix(".git").split("/")[-1], url, None))
    return found


def packages_from_resolved(path: pathlib.Path) -> list[tuple[str, str, str | None]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    out = []
    for pin in data.get("pins", []):
        state = pin.get("state", {})
        out.append((pin["identity"], pin.get("location", ""), state.get("version")))
    return out


def main() -> int:
    packages = packages_from_project()
    if "--resolved" in sys.argv:
        packages = packages_from_resolved(pathlib.Path(sys.argv[sys.argv.index("--resolved") + 1]))
    packages += [(name, url, version) for name, url, version in FONTS]
    packages.sort(key=lambda p: p[0].lower())
    font_names = {name for name, _, _ in FONTS}

    sections, summary, missing = [], [], []
    for name, url, version in packages:
        found = licence_for(url, version)
        if not found:
            missing.append(f"{name} ({url})")
            continue
        text, source, base = found
        if kind(text) == "Apache License 2.0":
            notice = notice_for(base)
            if notice:
                text += "\n\nNOTICE (the package's own notice file, which the Apache License 2.0 asks to be passed on):\n\n" + notice
        summary.append(f"  {name + (' (font)' if name in font_names else ''):<34} {kind(text)}")
        label = f"{name}" + (f" {version}" if version else "") + (" (font files)" if name in font_names else "")
        sections.append(f"{'=' * 78}\n{label}\n{url}\nLicence: {kind(text)} (from {source})\n{'=' * 78}\n\n{text}\n")
    if missing:
        print("No licence file found for: " + ", ".join(missing))
        print("Look the licence up by hand and add it to Slate/Resources/ThirdPartyNotices.txt, or take the package out.")
        return 1
    OUT.write_text(HEADER + "In this file:\n" + "\n".join(summary) + "\n\n" + "\n".join(sections), encoding="utf-8")
    print(f"Wrote {OUT.relative_to(IOS)}: {len(sections)} package(s)")
    print("\n".join(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
