#!/usr/bin/env bash
# Build Slate and run it in the iOS Simulator. No Apple account, signing or backend setup is needed: the app runs
# on-device (LocalBackend) and its welcome screen has "Continue with a demo account".
#
#   ./scripts/run-simulator.sh                      build, start a simulator, install and launch
#   ./scripts/run-simulator.sh --xcode              only generate the project and open it in Xcode
#   ./scripts/run-simulator.sh --device "iPhone 16" use a particular simulator
#   ./scripts/run-simulator.sh --screenshot a.png   also save a screenshot a few seconds after launch
#   ./scripts/run-simulator.sh --headless           don't open the Simulator window (for CI)
set -euo pipefail

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

cd "$(dirname "$0")/.."   # the ios/ folder

device=""
shot=""
open_xcode=0
headless=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --xcode) open_xcode=1 ;;
    --headless) headless=1 ;;
    --device) [[ $# -ge 2 ]] || die "--device needs a simulator name, for example --device \"iPhone 16\""; device="$2"; shift ;;
    --screenshot) [[ $# -ge 2 ]] || die "--screenshot needs a file name, for example --screenshot welcome.png"; shot="$2"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

[[ "$(uname)" == "Darwin" ]] || die "This needs a Mac with Xcode."
command -v xcodebuild >/dev/null 2>&1 || die "Xcode isn't installed. Install it from the App Store, open it once to accept the license, then run this again."
xcodebuild -version >/dev/null 2>&1 || die "Xcode is installed but isn't ready. Open Xcode once and accept the license, or run: sudo xcode-select -s /Applications/Xcode.app"

if ! command -v xcodegen >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || die "XcodeGen is needed. Install Homebrew from https://brew.sh, then run: brew install xcodegen"
  say "Installing XcodeGen with Homebrew"
  brew install xcodegen
fi

say "Generating Slate.xcodeproj"
xcodegen generate

if [[ $open_xcode -eq 1 ]]; then
  open Slate.xcodeproj
  say "Opened in Xcode. Choose an iPhone simulator at the top of the window and press Run (the play button)."
  exit 0
fi

# Pick the simulator: the one asked for, or the newest regular iPhone that is installed.
uuid_pattern='[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}'
if [[ -n "$device" ]]; then
  udid=$(xcrun simctl list devices available | grep -F "$device (" | grep -oE "$uuid_pattern" | tail -1 || true)
  [[ -n "$udid" ]] || die "No installed simulator is called \"$device\". See what you have with: xcrun simctl list devices available"
else
  udid=$(xcrun simctl list devices available | grep -E '^ +iPhone ' | grep -v ' SE ' | grep -oE "$uuid_pattern" | tail -1 || true)
  [[ -n "$udid" ]] || die "No iPhone simulator is installed. In Xcode open Settings, then Components, download the iOS Simulator, and run this again."
fi

say "Starting the simulator"
xcrun simctl boot "$udid" 2>/dev/null || true   # already running is fine
if [[ $headless -eq 0 ]]; then
  open -a Simulator --args -CurrentDeviceUDID "$udid"
fi
xcrun simctl bootstatus "$udid" -b >/dev/null

# With no Config/Secrets.xcconfig there is no development team, so build without signing, which is all a simulator needs.
signing=()
[[ -f Config/Secrets.xcconfig ]] || signing=(CODE_SIGNING_ALLOWED=NO)

say "Building Slate (the first build downloads Swift packages and can take several minutes)"
mkdir -p build
if ! xcodebuild build \
      -project Slate.xcodeproj \
      -scheme Slate \
      -configuration Debug \
      -destination "id=$udid" \
      -derivedDataPath build/DerivedData \
      ${signing[@]+"${signing[@]}"} \
      > build/xcodebuild.log 2>&1; then
  grep -E 'error:' build/xcodebuild.log | sort -u | head -30 >&2 || true
  die "The build failed. The full log is in ios/build/xcodebuild.log."
fi

app="build/DerivedData/Build/Products/Debug-iphonesimulator/Slate.app"
[[ -d "$app" ]] || die "The build finished but $app isn't there. Look in ios/build/xcodebuild.log."
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")

say "Installing and launching"
xcrun simctl install "$udid" "$app"
xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
xcrun simctl launch "$udid" "$bundle_id" >/dev/null

if [[ -n "$shot" ]]; then
  sleep 6
  xcrun simctl io "$udid" screenshot "$shot" >/dev/null 2>&1
  say "Saved a screenshot to $shot"
fi

say "Slate is running. On the welcome screen, tap \"Continue with a demo account\"."
