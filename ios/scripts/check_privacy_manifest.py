#!/usr/bin/env python3
"""Checks the app's privacy manifest (Config/PrivacyInfo.xcprivacy), the file Apple asks for at upload.

It fails when the file is broken, when the app starts using a system feature that has to be explained and the manifest does not
explain it, or when the manifest says the app tracks people. Run from the ios folder:

    python3 scripts/check_privacy_manifest.py
    python3 scripts/check_privacy_manifest.py path/to/Slate.app/PrivacyInfo.xcprivacy   # the copy inside a built app

Apple's lists of codes are at developer.apple.com/documentation/bundleresources/privacy_manifest_files.
"""
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT = ROOT / "Config" / "PrivacyInfo.xcprivacy"

# Data types Apple accepts, and the purposes the app may give. Anything else is a typo that App Store Connect rejects.
KNOWN_TYPES = {
    "NSPrivacyCollectedDataTypeName", "NSPrivacyCollectedDataTypeEmailAddress", "NSPrivacyCollectedDataTypePhoneNumber",
    "NSPrivacyCollectedDataTypePhysicalAddress", "NSPrivacyCollectedDataTypeOtherUserContactInfo",
    "NSPrivacyCollectedDataTypeContacts", "NSPrivacyCollectedDataTypeEmailsOrTextMessages",
    "NSPrivacyCollectedDataTypePhotosorVideos", "NSPrivacyCollectedDataTypeAudioData",
    "NSPrivacyCollectedDataTypeGameplayContent", "NSPrivacyCollectedDataTypeCustomerSupport",
    "NSPrivacyCollectedDataTypeOtherUserContent", "NSPrivacyCollectedDataTypeBrowsingHistory",
    "NSPrivacyCollectedDataTypeSearchHistory", "NSPrivacyCollectedDataTypeUserID", "NSPrivacyCollectedDataTypeDeviceID",
    "NSPrivacyCollectedDataTypePurchaseHistory", "NSPrivacyCollectedDataTypeProductInteraction",
    "NSPrivacyCollectedDataTypeAdvertisingData", "NSPrivacyCollectedDataTypeOtherUsageData",
    "NSPrivacyCollectedDataTypeCrashData", "NSPrivacyCollectedDataTypePerformanceData",
    "NSPrivacyCollectedDataTypeOtherDiagnosticData", "NSPrivacyCollectedDataTypeEnvironmentScanning",
    "NSPrivacyCollectedDataTypeHands", "NSPrivacyCollectedDataTypeHead", "NSPrivacyCollectedDataTypeOtherDataTypes",
    "NSPrivacyCollectedDataTypeHealth", "NSPrivacyCollectedDataTypeFitness", "NSPrivacyCollectedDataTypePaymentInfo",
    "NSPrivacyCollectedDataTypeCreditInfo", "NSPrivacyCollectedDataTypeOtherFinancialInfo",
    "NSPrivacyCollectedDataTypePreciseLocation", "NSPrivacyCollectedDataTypeCoarseLocation",
    "NSPrivacyCollectedDataTypeSensitiveInfo",
}
KNOWN_PURPOSES = {
    "NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising", "NSPrivacyCollectedDataTypePurposeDeveloperAdvertising",
    "NSPrivacyCollectedDataTypePurposeAnalytics", "NSPrivacyCollectedDataTypePurposeProductPersonalization",
    "NSPrivacyCollectedDataTypePurposeAppFunctionality", "NSPrivacyCollectedDataTypePurposeOther",
}

# Source patterns that need an explanation in the manifest, with the category they belong to.
REQUIRED_REASON_USES = {
    "NSPrivacyAccessedAPICategoryUserDefaults": r"\bUserDefaults\b|@AppStorage|\bNSUserDefaults\b",
    "NSPrivacyAccessedAPICategoryFileTimestamp": (
        r"\.creationDate\b|\.modificationDate\b|contentModificationDateKey|creationDateKey|"
        r"\.fileModificationDate|\.fileCreationDate|NSFileCreationDate|NSFileModificationDate|\b[fl]?stat\("
    ),
    "NSPrivacyAccessedAPICategorySystemBootTime": r"systemUptime|mach_absolute_time|\bkern\.boottime\b",
    "NSPrivacyAccessedAPICategoryDiskSpace": (
        r"volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|systemSize|attributesOfFileSystem|"
        r"NSURLVolumeAvailableCapacity"
    ),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": r"activeInputModes",
}
# A reason code in these categories means "the app's own use", which is how the app uses them.
OWN_USE_CODES = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
}


def source_uses() -> dict[str, list[str]]:
    """Which categories the Swift sources reach for, with the first few places."""
    found: dict[str, list[str]] = {}
    for folder in ("Slate", "Shared", "SlateWidgets"):
        for path in sorted((ROOT / folder).rglob("*.swift")):
            text = path.read_text(encoding="utf-8", errors="replace")
            for category, pattern in REQUIRED_REASON_USES.items():
                if re.search(pattern, text):
                    found.setdefault(category, []).append(str(path.relative_to(ROOT)))
    return found


def check(manifest_path: Path, look_at_sources: bool) -> list[str]:
    problems: list[str] = []
    try:
        manifest = plistlib.loads(manifest_path.read_bytes())
    except Exception as error:  # a broken file is the one thing worth stopping on
        return [f"{manifest_path} is not a readable property list: {error}"]

    if manifest.get("NSPrivacyTracking") is not False:
        problems.append("NSPrivacyTracking must be false: Slate Pro does not track people (the privacy policy says so).")
    if manifest.get("NSPrivacyTrackingDomains") not in ([], None):
        problems.append("NSPrivacyTrackingDomains must be empty: there is nothing to track.")

    declared: dict[str, set[str]] = {}
    for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
        category = entry.get("NSPrivacyAccessedAPIType")
        reasons = set(entry.get("NSPrivacyAccessedAPITypeReasons", []))
        if not category or not reasons:
            problems.append(f"An accessed-API entry needs a category and at least one reason code: {entry}")
            continue
        declared[category] = reasons
        wanted = OWN_USE_CODES.get(category)
        if wanted and not reasons & wanted:
            problems.append(f"{category} should give one of {sorted(wanted)} (the app's own use); it gives {sorted(reasons)}.")

    if look_at_sources:
        for category, files in source_uses().items():
            if category not in declared:
                problems.append(
                    f"The app uses {category} (for example in {', '.join(files[:3])}) but the manifest does not explain it. "
                    "Add an NSPrivacyAccessedAPITypes entry with Apple's reason code."
                )

    seen: set[str] = set()
    for entry in manifest.get("NSPrivacyCollectedDataTypes", []):
        kind = entry.get("NSPrivacyCollectedDataType")
        if kind not in KNOWN_TYPES:
            problems.append(f"Unknown collected data type: {kind!r}")
        if kind in seen:
            problems.append(f"{kind} is listed twice.")
        seen.add(kind)
        if entry.get("NSPrivacyCollectedDataTypeTracking") is not False:
            problems.append(f"{kind}: tracking must be false.")
        if not isinstance(entry.get("NSPrivacyCollectedDataTypeLinked"), bool):
            problems.append(f"{kind}: say whether it is linked to the person (true or false).")
        purposes = entry.get("NSPrivacyCollectedDataTypePurposes", [])
        if not purposes:
            problems.append(f"{kind}: give at least one purpose.")
        for purpose in purposes:
            if purpose not in KNOWN_PURPOSES:
                problems.append(f"{kind}: unknown purpose {purpose!r}")
            if "Advertising" in purpose:
                problems.append(f"{kind}: Slate Pro has no advertising, so {purpose} is wrong.")
    return problems


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    manifest_path = Path(args[0]) if args else DEFAULT
    # Sources are only compared when checking the file in the repository (a built app has no Swift files beside it).
    problems = check(manifest_path, look_at_sources=not args)
    if problems:
        print("Privacy manifest problems:")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print(f"Privacy manifest OK: {manifest_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
