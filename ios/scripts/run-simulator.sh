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

# Prints what this Mac has, so a problem can be diagnosed from a copy of the Terminal window.
diagnose() {
  {
    echo
    echo "----- Copy everything from here to the end and send it to Claude -----"
    echo "macOS: $(sw_vers -productVersion 2>&1)"
    echo "Xcode folder: $(xcode-select -p 2>&1)"
    xcodebuild -version 2>&1 | head -3
    echo "Free space: $(df -h / | tail -1 | awk '{print $4}')"
    echo "Simulator software installed:"
    xcrun simctl list runtimes 2>&1 | head -8
    echo "Phones available:"
    xcrun simctl list devices available 2>&1 | head -14
  } >&2
}

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

say "Generating Slate.xcodeproj"
"${xcodegen_cmd[@]}" generate

if [[ $open_xcode -eq 1 ]]; then
  open Slate.xcodeproj
  say "Opened in Xcode. Choose an iPhone simulator at the top of the window and press Run (the play button)."
  exit 0
fi

if ! xcrun simctl list devices available >/dev/null 2>&1; then
  diagnose
  die "Xcode's simulator tool isn't working yet. Open the Xcode app once, let it finish installing components, quit it, and run this again."
fi

# Pick the simulator: the one asked for, or the newest regular iPhone that is installed.
uuid_pattern='[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}'
pick_udid() {
  local list found
  if [[ -n "$device" ]]; then
    xcrun simctl list devices available | grep -F "$device (" | grep -oE "$uuid_pattern" | tail -1 || true
    return
  fi
  # Prefer the newest regular "iPhone N Pro", then a plain "iPhone N", then any iPhone that isn't a special shape.
  list=$(xcrun simctl list devices available | grep -E '^ +iPhone ' || true)
  found=$(printf '%s\n' "$list" | grep -E '^ +iPhone [0-9]+ Pro \(' | grep -oE "$uuid_pattern" | tail -1 || true)
  [[ -n "$found" ]] || found=$(printf '%s\n' "$list" | grep -E '^ +iPhone [0-9]+ \(' | grep -oE "$uuid_pattern" | tail -1 || true)
  [[ -n "$found" ]] || found=$(printf '%s\n' "$list" | grep -Ev ' (SE|Duo|Fold|Air)' | grep -oE "$uuid_pattern" | tail -1 || true)
  [[ -n "$found" ]] || found=$(printf '%s\n' "$list" | grep -oE "$uuid_pattern" | tail -1 || true)
  printf '%s\n' "$found"
}

udid=$(pick_udid)
if [[ -z "$udid" && -z "$device" ]]; then
  # Newer versions of Xcode don't come with the iPhone simulator. Ask Apple for it.
  say "No iPhone simulator found. Downloading it from Apple (several GB, so this can take a while)"
  xcodebuild -downloadPlatform iOS || true
  udid=$(pick_udid)
fi
if [[ -z "$udid" && -z "$device" ]]; then
  # The simulator software is there but no phone has been set up in it yet, so make one.
  runtime=$(xcrun simctl list runtimes available | grep -E '^iOS ' | tail -1 | sed -E 's/.* - (com\.apple\.CoreSimulator\.SimRuntime\.[^ ]+)$/\1/' || true)
  phone_type=$(xcrun simctl list devicetypes | grep -E '^iPhone ' | grep -v ' SE ' | tail -1 | sed -E 's/.*\((com\.apple\.CoreSimulator\.SimDeviceType\.[^)]+)\)$/\1/' || true)
  if [[ "$runtime" == com.apple.* && "$phone_type" == com.apple.* ]]; then
    say "Setting up an iPhone in the simulator"
    udid=$(xcrun simctl create "Slate iPhone" "$phone_type" "$runtime" 2>/dev/null || true)
  fi
fi
if [[ -z "$udid" ]]; then
  if [[ -n "$device" ]]; then
    diagnose
    die "No installed simulator is called \"$device\". See what you have with: xcrun simctl list devices available"
  fi
  diagnose
  die "There is still no iPhone simulator. Open Xcode, choose Xcode > Settings > Components, download the iOS simulator there, and run this again."
fi

say "Starting the simulator"
xcrun simctl boot "$udid" 2>/dev/null || true   # already running is fine
if [[ $headless -eq 0 ]]; then
  # The window that shows the phone is the Simulator app, or "Device Hub" in the newest Xcode. It lives inside Xcode,
  # and macOS doesn't always know where, so try the likely places.
  opened=0
  window_app=""
  for candidate in "$(xcode-select -p)/Applications/Simulator.app" "$(xcode-select -p)/Applications/Device Hub.app"; do
    if [[ -d "$candidate" ]]; then window_app="$candidate"; break; fi
  done
  if [[ -z "$window_app" ]]; then
    window_app=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.iphonesimulator'" 2>/dev/null | head -1 || true)
  fi
  if [[ -z "$window_app" ]]; then
    window_app=$(mdfind -name "Device Hub.app" 2>/dev/null | head -1 || true)
  fi
  if [[ -n "$window_app" && -d "$window_app" ]]; then
    open "$window_app" --args -CurrentDeviceUDID "$udid" && opened=1 || true
  fi
  if [[ $opened -eq 0 ]]; then
    open -a "Device Hub" 2>/dev/null && opened=1 || open -a Simulator 2>/dev/null && opened=1 || true
  fi
  if [[ $opened -eq 0 ]]; then
    say "Couldn't open the phone window by itself. Press Command and Space, type Simulator (or Device Hub), and press Return. Or in Xcode choose Xcode > Open Developer Tool."
  fi
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
  diagnose
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
