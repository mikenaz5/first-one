#!/usr/bin/env python3
"""Keeps every asset in Slate Pro ours: carried inside the app (or drawn by it), or served from our own storage, and written
up in docs/ASSETS.md with where it came from.

Why: a picture, font or script fetched from somebody else's server is both a copyright question (is it ours to show?) and a
data question (that server learns who opened the app, from where, and when). So nothing is fetched from anyone else.

It fails when:
  1. A string in the app, the widget or the shared code holds an address on a server that isn't ours or isn't on the short
     list below (each with its reason).
  2. Code starts to load or open something from the network (AsyncImage, URLSession, a web view, a video player, a link, a
     share sheet, a custom font) in a file that isn't on the list below. A new use is allowed once someone has decided it is
     fine, written the reason here and in docs/ASSETS.md.
  3. A picture, font, sound or video file is added to the app and docs/ASSETS.md doesn't name it.
  4. The website pulls a font, script, picture, style sheet, frame or form from another address.
  5. A code package is added (project.yml) without a notice for it in Slate/Resources/ThirdPartyNotices.txt and a row in
     docs/ASSETS.md. With `--resolved <Package.resolved>` (CI) every package the build really resolved, including the ones
     those packages bring in, must have a notice too.

    python3 scripts/check_assets.py
    python3 scripts/check_assets.py --resolved path/to/Package.resolved
"""
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
IOS = HERE.parent
SITE = IOS.parent / "site"
DOC = IOS / "docs" / "ASSETS.md"
NOTICES = IOS / "Slate" / "Resources" / "ThirdPartyNotices.txt"

APP_CODE = [IOS / "Slate", IOS / "Shared", IOS / "SlateWidgets"]
ASSET_EXTENSIONS = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".svg", ".pdf", ".ttf", ".otf", ".woff", ".woff2",
    ".mp3", ".wav", ".m4a", ".aac", ".caf", ".mp4", ".mov", ".m4v", ".lottie", ".riv",
}

# 1. Addresses that may appear in a string in the app. Our own site is built from AppConfig.bookingLinkHost, never typed in.
ALLOWED_HOSTS = {
    "calendar.google.com": "the 'Add to Google Calendar' link a person taps; it opens their browser, and nothing is loaded in the app",
    "paypal.me": "grey hint text inside a field, never opened",
    "slateproapp.com": "our own site",
}
OWN_HOST_INTERPOLATIONS = ("\\(bookingLinkHost)", "\\(AppConfig.bookingLinkHost)")
ALLOWED_SCHEMES = {"slate": "our own link scheme, opens the app"}

# 2. Where code may reach out, open something or use a font that isn't in the app. File (relative to ios/) -> why it is fine.
REACHES = {
    "AsyncImage(": {
        "Slate/DesignSystem/Components.swift": "pictures from our own storage (SupabaseBackend.publicURL), never an address a person typed",
        "Slate/Features/Client/FeaturedCreatorsView.swift": "a creator's cover, from our own storage",
        "Slate/Features/Profile/PortfolioSection.swift": "portfolio pictures, from our own storage",
    },
    "URLSession": {
        "Slate/Core/SupabaseBackend+Files.swift": "uploads delivered files to our own storage",
        "Slate/Services/FileTransfer.swift": "downloads delivered files from our own storage",
    },
    "WKWebView": {},
    "SFSafariViewController": {},
    "webAuthenticationSession": {
        "Slate/Features/Client/CardsViews.swift": "Stripe's own page for adding a card, in the system's sign-in sheet",
        "Slate/Features/Payments/PaymentViews.swift": "Stripe's own page for connecting a payout account, in the system's sign-in sheet",
    },
    "Link(destination": {
        "Slate/Features/Delivery/DeliveryViews.swift": "a delivery link the creator chose to share, opened in the browser on a tap",
        "Slate/Features/Teams/AboutSection.swift": "our privacy policy, terms and support pages",
        "Slate/Features/Teams/MembersView.swift": "an invite link the person is sharing",
        "SlateWidgets/SlateWidgets.swift": "opens the app from the widget",
    },
    "openURL": {
        "Slate/Features/Notifications/NotificationSettingsView.swift": "opens the Settings app",
        "Slate/Features/Payments/PaymentViews.swift": "a payment link the creator chose to share, opened on a tap",
        "Slate/Features/Teams/CalendarConnectView.swift": "the calendar subscription link the person asked for",
        "Slate/Features/Teams/PlanSheet.swift": "our terms and privacy policy",
    },
    "UIApplication.shared.open": {
        "Slate/Features/Availability/CalendarSyncSection.swift": "opens the Settings app",
    },
    "VideoPlayer(": {
        "Slate/Features/Files/FileViewer.swift": "plays a delivered video, from our own storage",
        "Slate/Features/Profile/PortfolioSection.swift": "plays a portfolio video, from our own storage",
    },
    "AVPlayer(": {
        "Slate/Features/Files/FileViewer.swift": "plays a delivered video, from our own storage",
        "Slate/Features/Profile/PortfolioSection.swift": "plays a portfolio video, from our own storage",
    },
    "AVURLAsset": {
        "Slate/Core/MediaProcessing.swift": "reads a video file already on the phone",
        "Slate/Services/FileTransfer.swift": "reads a video file already on the phone",
        "Slate/Services/PreviewMaker.swift": "reads a video file already on the phone",
    },
    "ShareLink": {
        "Slate/Features/Contracts/ContractViews.swift": "the system share sheet, for the person's own contract PDF",
        "Slate/Features/Home/HomeView.swift": "the system share sheet, for the person's own booking link",
        "Slate/Features/Profile/ProfileView.swift": "the system share sheet, for the person's own booking link",
        "Slate/Features/Teams/MembersView.swift": "the system share sheet, for an invite link",
    },
    "UIFont(name:": {
        "Slate/Services/ContractPDF.swift": "Snell Roundhand by name, to draw a typed signature into a picture (so no font is copied into the PDF)",
    },
    ".custom(": {
        "Slate/Features/Contracts/ContractViews.swift": "Snell Roundhand, a font built into iOS, used by name for a typed signature; nothing is bundled",
        "Slate/Features/Contracts/SignatureCapture.swift": "Snell Roundhand, a font built into iOS, used by name for a typed signature; nothing is bundled",
    },
    "UIAppFonts": {},
}

# 4. The website and the sign-in email may link to these addresses (a link someone taps), and load nothing from anywhere
# but themselves. They name fonts only from this list: fonts the visitor's own device already has. Nothing is ever served.
SITE_LINK_HOSTS: dict[str, str] = {}
WEB_FILES = [IOS.parent / "site", IOS / "supabase" / "email-templates"]
DEVICE_FONTS = {
    "system-ui", "-apple-system", "blinkmacsystemfont", "sf pro text", "sf pro display", "sf pro rounded", "ui-rounded",
    "sf mono", "ui-monospace", "menlo", "consolas", "monaco", "segoe ui", "roboto", "helvetica", "helvetica neue", "arial",
    "sans-serif", "serif", "monospace", "cursive", "inherit", "snell roundhand", "segoe script", "brush script mt",
}

failures: list[str] = []


def fail(text: str) -> None:
    failures.append(text)


def rel(path: pathlib.Path) -> str:
    return str(path.relative_to(IOS)) if IOS in path.parents else str(path.relative_to(IOS.parent))


def swift_files():
    for root in APP_CODE:
        if root.exists():
            yield from sorted(root.rglob("*.swift"))


def strip_comment(line: str) -> str:
    """The line without a trailing // comment (a // inside a string, like https://, stays)."""
    inside = False
    escaped = False
    for i, ch in enumerate(line):
        if escaped:
            escaped = False
        elif ch == "\\" and inside:
            escaped = True
        elif ch == '"':
            inside = not inside
        elif ch == "/" and not inside and line[i : i + 2] == "//":
            return line[:i]
    return line


LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
ADDRESS = re.compile(r"([A-Za-z][A-Za-z0-9+.\-]*)://([^/\s\"]*)")


# ---------------------------------------------------------------------------
# 1. Addresses in code
# ---------------------------------------------------------------------------
def check_addresses() -> int:
    seen = 0
    for path in swift_files():
        for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if raw.strip().startswith("//"):
                continue
            for literal in LITERAL.findall(strip_comment(raw)):
                for scheme, host in ADDRESS.findall(literal):
                    seen += 1
                    if scheme.lower() in ("http", "https"):
                        if host == "" or any(host.startswith(own) for own in OWN_HOST_INTERPOLATIONS):
                            continue  # "https://" as words in a hint, or our own site
                        bare = host.split(":")[0].lower()
                        if bare in ALLOWED_HOSTS:
                            continue
                        fail(f"{rel(path)}:{number}: an address on {host}, which isn't ours. Everything the app shows or loads "
                             f"comes from the app or from our own storage. If this is a link a person taps, add {bare} to "
                             "ALLOWED_HOSTS in scripts/check_assets.py with the reason, and to docs/ASSETS.md.")
                    elif scheme.lower() not in ALLOWED_SCHEMES:
                        fail(f"{rel(path)}:{number}: a '{scheme}://' address. Add the scheme to ALLOWED_SCHEMES with the reason if it is right.")
    return seen


# ---------------------------------------------------------------------------
# 2. Places that reach out
# ---------------------------------------------------------------------------
def check_reaches() -> None:
    project = (IOS / "project.yml").read_text(encoding="utf-8")
    for pattern, allowed in REACHES.items():
        found = []
        for path in swift_files():
            text = "\n".join(strip_comment(l) for l in path.read_text(encoding="utf-8").splitlines() if not l.strip().startswith("//"))
            if pattern in text:
                found.append(rel(path))
        if pattern == "UIAppFonts" and pattern in project:
            found.append("project.yml")
        for name in found:
            if name not in allowed:
                fail(f"{name} uses {pattern}. That reaches outside the app, or uses a font the app doesn't carry. If it is "
                     "fine, add the file to REACHES in scripts/check_assets.py with the reason (and say so in docs/ASSETS.md).")


# ---------------------------------------------------------------------------
# 3. Files the app carries
# ---------------------------------------------------------------------------
def check_bundled_files() -> list[str]:
    doc = DOC.read_text(encoding="utf-8") if DOC.exists() else ""
    if not doc:
        fail("docs/ASSETS.md is missing. It lists every file the app carries and where it came from.")
    carried = []
    for root in APP_CODE + [IOS / "Config"]:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*")):
            if path.is_file() and path.suffix.lower() in ASSET_EXTENSIONS:
                carried.append(rel(path))
    for name in carried:
        if name not in doc:
            fail(f"{name} is carried inside the app but docs/ASSETS.md doesn't name it. Write down who made it and under what "
                 "licence, or take it out.")
    return carried


# ---------------------------------------------------------------------------
# 4. The website
# ---------------------------------------------------------------------------
EXTERNAL = re.compile(r"^(?:https?:)?//", re.I)


def style_segments(path: pathlib.Path, text: str) -> list[str]:
    """The parts of a file that are style rules: all of a style sheet, or the style attributes and <style> blocks of a page."""
    if path.suffix.lower() == ".css":
        return [text]
    found = re.findall(r'style\s*=\s*"([^"]*)"', text, re.I) + re.findall(r"style\s*=\s*'([^']*)'", text, re.I)
    found += re.findall(r"<style[^>]*>(.*?)</style>", text, re.I | re.S)
    return found


def font_names(segments: list[str]) -> list[str]:
    """The font names asked for, from font-family and the font shorthand."""
    families = []
    for segment in segments:
        families += re.findall(r"font-family\s*:\s*([^;}]+)", segment, re.I)
        families += re.findall(r"font\s*:\s*[^;}]*?(?:px|rem|em|pt|%)(?:/[\d.]+(?:px|rem|em|pt)?)?\s+([^;}]+)", segment, re.I)
    names = []
    for family in families:
        for name in family.split(","):
            clean = name.strip().strip("'\"").strip().lower()
            if clean:
                names.append(clean)
    return names


def check_site() -> int:
    pages = 0
    document = DOC.read_text(encoding="utf-8") if DOC.exists() else ""
    for root in WEB_FILES:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            name = str(path.relative_to(IOS.parent))
            if path.suffix.lower() in ASSET_EXTENSIONS:
                if name not in document:
                    fail(f"{name} is a picture, font or media file served with the site or sent in an email, and docs/ASSETS.md doesn't name it.")
                continue
            if path.suffix.lower() not in (".html", ".css", ".js"):
                continue
            pages += 1
            text = path.read_text(encoding="utf-8")
            for tag in ("script", "iframe", "embed", "object"):
                if re.search(rf"<{tag}\b", text, re.I):
                    fail(f"{name}: a <{tag}> tag. The site and the email have none: plain pages and one style sheet.")
            if re.search(r"@import", text, re.I):
                fail(f"{name}: an @import. Styles come from our own style sheet only.")
            if re.search(r"@font-face", text, re.I):
                fail(f"{name}: an @font-face. We serve no fonts: pages name only fonts the visitor's device already has.")
            for font in font_names(style_segments(path, text)):
                if font not in DEVICE_FONTS:
                    fail(f"{name}: the font '{font}' isn't one every device has. Nothing is served, so it would silently fall back. "
                         "Use a system font, or (if a real font is wanted) add its file, its licence and a row in docs/ASSETS.md first.")
            for found in re.findall(r"url\(\s*['\"]?([^)'\"]+)", text, re.I):
                if EXTERNAL.match(found.strip()):
                    fail(f"{name}: url({found}) loads something from another address.")
            for attribute, value in re.findall(r"""\b(src|href|action|srcset|poster|data)\s*=\s*["']([^"']*)["']""", text, re.I):
                value = value.strip()
                if not EXTERNAL.match(value):
                    continue
                context = text[max(0, text.rfind("<", 0, text.find(value))) : text.find(value)]
                tag_match = re.match(r"<\s*([a-zA-Z0-9]+)", context)
                tag = tag_match.group(1).lower() if tag_match else ""
                host = re.sub(r"^(?:https?:)?//", "", value).split("/")[0].split(":")[0].lower()
                if tag == "a" and attribute.lower() == "href" and host in SITE_LINK_HOSTS:
                    continue
                fail(f"{name}: {attribute}=\"{value}\" points at another address. Nothing is loaded from anywhere else"
                     + (" (a plain link someone taps needs its host in SITE_LINK_HOSTS)." if tag == "a" else "."))
    return pages


# ---------------------------------------------------------------------------
# 5. Code packages and their notices
# ---------------------------------------------------------------------------
def package_names_in_project() -> list[str]:
    names = []
    for url in re.findall(r"^\s+url:\s*(\S+)", (IOS / "project.yml").read_text(encoding="utf-8"), re.M):
        names.append(url.rstrip("/").removesuffix(".git").split("/")[-1].lower())
    return names


def check_notices(resolved: pathlib.Path | None) -> list[str]:
    notices = NOTICES.read_text(encoding="utf-8").lower() if NOTICES.exists() else ""
    doc = DOC.read_text(encoding="utf-8").lower() if DOC.exists() else ""
    if not notices:
        fail("Slate/Resources/ThirdPartyNotices.txt is missing. It carries the licence notices of the code packages the app is built with.")
    names = package_names_in_project()
    for name in names:
        if name not in notices:
            fail(f"The package {name} has no notice in Slate/Resources/ThirdPartyNotices.txt.")
        if name not in doc:
            fail(f"The package {name} has no row in docs/ASSETS.md.")
    pins: list[str] = []
    if resolved:
        data = json.loads(resolved.read_text(encoding="utf-8"))
        for pin in data.get("pins", []):
            identity = str(pin.get("identity", "")).lower()
            state = pin.get("state", {})
            version = state.get("version") or (str(state.get("revision", ""))[:10])
            pins.append(f"{identity} {version} {pin.get('location', '')}")
            if identity not in notices:
                fail(f"The build resolved the package {identity} {version} ({pin.get('location', '')}), which has no notice in Slate/Resources/ThirdPartyNotices.txt. "
                     "Add its licence text (scripts/update_notices.py does it).")
    return pins


def main() -> int:
    resolved = None
    if "--resolved" in sys.argv:
        resolved = pathlib.Path(sys.argv[sys.argv.index("--resolved") + 1])
        if not resolved.exists():
            print(f"--resolved: {resolved} does not exist")
            return 2
    addresses = check_addresses()
    check_reaches()
    carried = check_bundled_files()
    pages = check_site()
    pins = check_notices(resolved)

    if resolved:
        print("Packages the build resolved:")
        for pin in pins:
            print("  " + pin)
    if failures:
        print(f"{len(failures)} problem(s):\n")
        for line in failures:
            print(" - " + line)
        return 1
    print(f"Every asset is ours or written up: {addresses} address(es) in code checked, {len(carried)} file(s) carried, "
          f"{pages} website file(s), {len(package_names_in_project())} package(s) with notices.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
