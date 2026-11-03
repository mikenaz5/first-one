"""Checks the website in ../site against the app.

    python3 scripts/check_site.py            # what CI runs: the pages exist, links inside the site work,
                                             #   and the addresses in the app point at real pages
    python3 scripts/check_site.py --release  # also fails while a draft banner or a [[placeholder]] is still on a page

The privacy policy, terms and support pages are what Apple asks for on the store page, and the app links to them
(AppConfig.privacyURL, termsURL, supportURL), so a rename of one without the other should fail here.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SITE = ROOT / "site"
MODELS = ROOT / "ios" / "Slate" / "Core" / "Models.swift"

problems = []


def page_for(url_path: str):
    """The file a path on the site is served from: /privacy/ -> site/privacy/index.html, /style.css -> site/style.css."""
    path = url_path.split("#")[0].split("?")[0]
    if path.endswith("/"):
        return SITE / path.strip("/") / "index.html" if path.strip("/") else SITE / "index.html"
    candidate = SITE / path.strip("/")
    if candidate.is_file():
        return candidate
    index = candidate / "index.html"
    return index if index.is_file() else candidate


pages = sorted(SITE.rglob("*.html"))
if not pages:
    problems.append("site/ has no pages")

for required in ("index.html", "privacy/index.html", "terms/index.html", "support/index.html", "style.css"):
    if not (SITE / required).is_file():
        problems.append(f"site/{required} is missing")

# Links that stay on the site must go somewhere.
for page in pages:
    text = page.read_text()
    for href in re.findall(r'(?:href|src)="([^"]+)"', text):
        if href.startswith(("http://", "https://", "mailto:", "#")):
            continue
        if href.startswith("/") and not page_for(href).is_file():
            problems.append(f"{page.relative_to(ROOT)} links to {href}, which does not exist")
        elif not href.startswith("/"):
            problems.append(f"{page.relative_to(ROOT)} has a relative link ({href}); use a path that starts with /")
    if "<title>" not in text or 'name="viewport"' not in text:
        problems.append(f"{page.relative_to(ROOT)} needs a title and a viewport tag")

# The app's addresses.
models = MODELS.read_text()
host = re.search(r'static let bookingLinkHost = "([^"]+)"', models)
if not host:
    problems.append("AppConfig.bookingLinkHost not found")
for name in ("privacyURL", "termsURL", "supportURL"):
    match = re.search(rf'static let {name} = URL\(string: "https://\\\(bookingLinkHost\)(/[^"]*)"\)', models)
    if not match:
        problems.append(f"AppConfig.{name} not found or not on the website's host")
    elif not page_for(match.group(1) + "/").is_file():
        problems.append(f"AppConfig.{name} is {match.group(1)}, but there is no such page in site/")
if host:
    email = f"support@{host.group(1)}"
    if f'static let supportEmail = "support@\\(bookingLinkHost)"' not in models:
        problems.append("AppConfig.supportEmail is not support@ at the website's host")
    for page in pages:
        for found in re.findall(r"mailto:([^\"?]+)", page.read_text()):
            if found != email:
                problems.append(f"{page.relative_to(ROOT)} mails {found}, not {email}")

if "--release" in sys.argv:
    for page in pages:
        text = page.read_text()
        left = len(re.findall(r"\[\[", text))
        if left:
            problems.append(f"{page.relative_to(ROOT)} still has {left} [[placeholder]] to fill in")
        if 'class="draft"' in text:
            problems.append(f"{page.relative_to(ROOT)} still carries the draft banner")

if problems:
    print("The website and the app disagree:")
    for problem in problems:
        print("  -", problem)
    sys.exit(1)
print(f"The website is in step with the app ({len(pages)} pages).")
