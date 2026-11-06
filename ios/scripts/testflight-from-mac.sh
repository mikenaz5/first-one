#!/usr/bin/env bash
# Build Slate Pro for real iPhones on THIS Mac and send it to App Store Connect, where TestFlight picks it up.
#
# It signs with the Apple ID that is signed in to Xcode (Xcode > Settings > Accounts). That is on purpose: Apple's
# web service refuses to let an API key handle App Groups, which the widget needs, so the GitHub button can't do it.
#
#   bash scripts/testflight-from-mac.sh                  build and upload
#   bash scripts/testflight-from-mac.sh --team ABCDE12345   say which Apple team (otherwise it asks, or reads Secrets.xcconfig)
#   bash scripts/testflight-from-mac.sh --version 1.0.0     the version people see (otherwise the one in project.yml)
#
# Before the first run:
#   1. Xcode > Settings > Accounts: add your Apple ID (the one the developer account belongs to).
#   2. bash scripts/setup-server.sh, so the app knows your Supabase project (this script stops if it doesn't).
set -euo pipefail

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

cd "$(dirname "$0")/.."   # the ios/ folder

team="${APPLE_TEAM_ID:-}"
version=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) [[ $# -ge 2 ]] || die "--team needs your 10-character Team ID, for example --team ABCDE12345"; team="$2"; shift ;;
    --version) [[ $# -ge 2 ]] || die "--version needs a number, for example --version 1.0.0"; version="$2"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

[[ "$(uname)" == "Darwin" ]] || die "This needs a Mac with Xcode."
command -v xcodebuild >/dev/null 2>&1 || die "Xcode isn't installed. Install it from the App Store, open it once to accept the license, then run this again."
xcodebuild -version >/dev/null 2>&1 || die "Xcode is installed but isn't ready. Open Xcode once and accept the license, or run: sudo xcode-select -s /Applications/Xcode.app"

secrets=Config/Secrets.xcconfig

# The app must know its server, or the TestFlight build would open to a screen with nothing in it (the demo account exists in
# test builds only).
value_of() { grep -E "^[[:space:]]*$1[[:space:]]*=" "$secrets" 2>/dev/null | tail -1 | sed -E 's/^[^=]*=[[:space:]]*//' || true; }
[[ -f "$secrets" ]] || die "The app doesn't know your Supabase project yet. Run this first, then try again:  bash scripts/setup-server.sh"
[[ -n "$(value_of SUPABASE_URL)" && -n "$(value_of SUPABASE_ANON_KEY)" ]] \
  || die "Config/Secrets.xcconfig has no Supabase address or key. Run this first, then try again:  bash scripts/setup-server.sh"
case "$(value_of SUPABASE_ANON_KEY)" in
  sb_secret_*) die "Config/Secrets.xcconfig holds a SECRET Supabase key. Only the publishable key (sb_publishable_...) may go in the app. Run: bash scripts/setup-server.sh" ;;
esac

if [[ -z "$team" ]]; then team="$(value_of DEVELOPMENT_TEAM)"; fi
if [[ -z "$team" ]]; then
  printf 'Your Apple Team ID (10 letters and numbers; developer.apple.com/account, then Membership details): '
  read -r team
fi
team="$(printf '%s' "$team" | tr -d '[:space:]')"
[[ "$team" =~ ^[A-Za-z0-9]{10}$ ]] || die "A Team ID is exactly 10 letters and numbers, like ABCDE12345. You gave: '$team'"

# A friendly hint if Xcode has no Apple ID yet (Xcode keeps the list of accounts in its settings).
if ! defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists >/dev/null 2>&1; then
  printf '\nNote: Xcode doesn'"'"'t seem to have an Apple ID yet. If the build says "No Account for Team", open Xcode, choose\n      Xcode > Settings > Accounts, press +, add your Apple ID, then run this again.\n'
fi

# XcodeGen turns project.yml into the Xcode project. Use the copy that is installed, or Homebrew's, or download it.
xcodegen_cmd=(xcodegen)
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    say "Installing XcodeGen with Homebrew"
    brew install xcodegen
  else
    say "Downloading XcodeGen, the small tool that makes the Xcode project"
    tools="$PWD/build/tools"
    mkdir -p "$tools"
    curl -fsSL -o "$tools/xcodegen.zip" "https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip" \
      || die "Couldn't download XcodeGen. Check your internet connection and try again."
    unzip -oq "$tools/xcodegen.zip" -d "$tools"
    found=$(find "$tools" -type f -name xcodegen -perm -u+x | head -1)
    [[ -n "$found" ]] || die "Downloaded XcodeGen but couldn't find the program inside it."
    xcodegen_cmd=("$found")
  fi
fi

# The settings file is changed only for this build (your team, and the entitlements that include notifications), and put back
# exactly as it was when the script ends, so your simulator runs are not affected.
backup="$(mktemp "${TMPDIR:-/tmp}/slate-secrets.XXXXXX")"
cp "$secrets" "$backup"
restore() { cp "$backup" "$secrets" 2>/dev/null || true; rm -f "$backup"; }
trap restore EXIT
{
  grep -vE '^[[:space:]]*(DEVELOPMENT_TEAM|CODE_SIGN_ENTITLEMENTS)[[:space:]]*=' "$backup" || true
  echo "DEVELOPMENT_TEAM = $team"
  # Sign in with Apple, App Groups and push notifications. Xcode switches notifications to the live (production) kind itself
  # for an App Store build.
  echo "CODE_SIGN_ENTITLEMENTS = Config/Slate.Push.entitlements"
} > "$secrets"

say "Generating Slate.xcodeproj"
"${xcodegen_cmd[@]}" generate

# Each build needs a bigger number than the one before; the date and time always are (for example 261106.1542).
build_number="$(date +%y%m%d.%H%M)"
mkdir -p build
archive="build/Slate-testflight.xcarchive"
rm -rf "$archive" build/testflight-export
extra=()
if [[ -n "$version" ]]; then extra+=("MARKETING_VERSION=$version"); fi

explain_failure() {
  local log="$1"
  {
    echo
    echo "----- What went wrong -----"
    grep -E "error:" "$log" | sort -u | head -12 || true
    if grep -qE "No Account for Team|Communication with Apple failed|Authentication failed|not signed in|provide your Apple ID" "$log"; then
      echo
      echo "Xcode doesn't have your Apple ID. Open Xcode, choose Xcode > Settings (or press the command key and comma),"
      echo "click Accounts, press +, choose Apple ID, sign in with the Apple ID your developer account belongs to, then run this again."
    fi
    if grep -qE "No profiles for|doesn't include|provisioning profile" "$log"; then
      echo
      echo "Xcode couldn't make the signing files. Check that developer.apple.com > Certificates, Identifiers & Profiles > Identifiers"
      echo "lists com.slateproapp.app and com.slateproapp.app.widgets, both with App Groups ticked and set to group.com.slateproapp.app."
    fi
    echo
    echo "The whole log is in ios/$log. Copy everything above and send it to Claude."
  } >&2
}

say "Building Slate Pro for iPhones (this takes a few minutes the first time)"
if ! xcodebuild archive \
    -project Slate.xcodeproj -scheme Slate -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$team" \
    CURRENT_PROJECT_VERSION="$build_number" \
    ${extra[@]+"${extra[@]}"} > build/testflight-archive.log 2>&1; then
  explain_failure build/testflight-archive.log
  exit 1
fi
tail -n 3 build/testflight-archive.log

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

say "Sending it to App Store Connect"
if ! xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist build/ExportOptions.plist \
    -exportPath build/testflight-export \
    -allowProvisioningUpdates > build/testflight-export.log 2>&1; then
  explain_failure build/testflight-export.log
  exit 1
fi
tail -n 5 build/testflight-export.log

say "Done. Build $build_number is on its way to Apple."
echo "In App Store Connect, open your app, then TestFlight. The build shows up after 10 to 30 minutes of \"Processing\"."
echo "Then add it to your testing group and install it from the TestFlight app on your iPhone (guide: docs/APP_STORE.md, Part D)."
