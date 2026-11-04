#!/usr/bin/env bash
# Connect Slate Pro to your own Supabase project (the online server): put the database and the first server functions
# online, and, if you say yes at the end, point the app at it. Run it once, from the ios folder:
#
#   bash scripts/setup-server.sh
#
# It asks for your project's address and its publishable key (neither is secret). Supabase itself asks for the database
# password you chose when you made the project; this script never sees it. It never asks for the secret key, and refuses
# one if you paste it: the secret key never goes in the app, in this repository, or in a chat.
set -euo pipefail

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
trap 'printf "\nSomething went wrong in the step above. Copy this whole Terminal window and send it to Claude.\n" >&2' ERR

cd "$(dirname "$0")/.."   # the ios/ folder

if ! command -v supabase >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    say "Installing Supabase's command-line tool with Homebrew"
    brew install supabase/tap/supabase
  else
    # No Homebrew? Download the tool itself (one small program) into this folder, the way run-simulator.sh gets XcodeGen.
    case "$(uname -m)" in
      arm64|aarch64) chip=arm64 ;;
      *) chip=amd64 ;;
    esac
    say "Downloading Supabase's command-line tool (about 50 MB)"
    tools="$PWD/build/tools"
    mkdir -p "$tools"
    curl -fsSL -o "$tools/supabase.tar.gz" "https://github.com/supabase/cli/releases/latest/download/supabase_darwin_${chip}.tar.gz" \
      || die "Couldn't download Supabase's tool. Check your internet connection and run this again."
    tar -xzf "$tools/supabase.tar.gz" -C "$tools" supabase \
      || die "Downloaded Supabase's tool but couldn't open it."
    chmod +x "$tools/supabase"
    export PATH="$tools:$PATH"
  fi
fi
command -v supabase >/dev/null 2>&1 || die "Supabase's command-line tool isn't available. Send me this whole window."

ask() { local answer; read -r -p "$1" answer; printf '%s' "$answer"; }

# 1. The address and the publishable key. Both are on the project's page in the Supabase dashboard (Connect, or Settings ▸ API Keys).
url=$(ask "Project URL (looks like https://abcdefghijklmnopqrst.supabase.co): ")
url=$(printf '%s' "$url" | tr -d '[:space:]')
url="${url%/}"
ref=$(printf '%s' "$url" | sed -nE 's#^https://([a-z0-9]+)\.supabase\.co$#\1#p')
[[ -n "$ref" ]] || die "That doesn't look like a project URL. It starts with https:// and ends with .supabase.co"

key=$(ask "Publishable key (starts with sb_publishable_): ")
key=$(printf '%s' "$key" | tr -d '[:space:]')
case "$key" in
  sb_secret_*) die "That is the SECRET key. Stop and don't use it here. Use the one that starts with sb_publishable_ (it is safe to put in the app)." ;;
  sb_publishable_*|eyJ*) ;;
  *) die "That doesn't look like a publishable key. It starts with sb_publishable_" ;;
esac
if [[ "$key" == eyJ* ]]; then
  # An older style of key. Refuse the powerful one (it says service_role inside).
  payload=$(printf '%s' "$key" | cut -d. -f2 | tr '_-' '/+')
  while (( ${#payload} % 4 )); do payload="$payload="; done
  if printf '%s' "$payload" | { base64 -D 2>/dev/null || base64 -d 2>/dev/null || true; } | grep -q 'service_role'; then
    die "That key has full access to your data (service_role). Don't use it here. Use the publishable key, or the one called anon."
  fi
fi

# 2. Log in, link this folder to the project and put the database online.
if ! supabase projects list >/dev/null 2>&1; then
  say "Logging in to Supabase (a browser window opens; approve it there)"
  supabase login
fi

if [[ ! -f supabase/config.toml ]]; then
  say "Setting up the Supabase folder"
  printf 'n\nn\n' | supabase init >/dev/null 2>&1 || true
  [[ -f supabase/config.toml ]] || die "Couldn't set up the Supabase folder. Run  supabase init  in the ios folder and send me what it prints."
fi

say "Linking to your project"
supabase link --project-ref "$ref"

# Newer versions of the tool push to a copy on this Mac unless told to use the linked project (--remote); older ones
# always use the linked project and don't know the word.
push_target=()
if supabase db push --help 2>&1 | grep -q -- '--remote'; then push_target=(--remote); fi

say "Putting the database online. Supabase may ask for the database password you chose when you made the project (typing shows nothing; that is normal), then lists what it will add and asks you to confirm."
supabase db push ${push_target[@]+"${push_target[@]}"}

# 3. The server functions that need no outside account. The payment, push and billing ones come later, with their own
#    setup in README.md ("Turning on real payments" and the sections after it).
deploy() { supabase functions deploy "$@" --use-api 2>/dev/null || supabase functions deploy "$@"; }
say "Putting the first server functions online"
deploy delete-account
deploy calendar-feed --no-verify-jwt

# 4. Optionally point the app at the project.
say "The server is ready: $url"
echo "Pointing the app at it changes how it behaves on this Mac:"
echo "  - the on-device demo account goes away (the app talks to your server instead);"
echo "  - creators sign in with Sign in with Apple, which needs a paid Apple Developer account, your team ID in"
echo "    Config/Secrets.xcconfig, and Apple switched on in Supabase (Authentication, then Providers);"
echo "  - clients can sign in with an emailed code."
echo "Say no to keep trying the app with the demo account."
answer=$(ask "Point the app at this server now? (y/N): ")
if [[ "$answer" == [yY]* ]]; then
  secrets=Config/Secrets.xcconfig
  tmp=$(mktemp)
  if [[ -f "$secrets" ]]; then
    cp "$secrets" "$secrets.bak"
    grep -vE '^[[:space:]]*(SUPABASE_URL|SUPABASE_ANON_KEY)[[:space:]]*=' "$secrets" > "$tmp" || true
  fi
  {
    echo "// Written by scripts/setup-server.sh. The // in the address is escaped because xcconfig reads // as a comment."
    echo "SUPABASE_URL = https:/\$()/$ref.supabase.co"
    echo "SUPABASE_ANON_KEY = $key"
    echo
    cat "$tmp"
  } > "$secrets"
  rm -f "$tmp"
  say "Saved to ios/Config/Secrets.xcconfig. To go back to the demo account, delete that file."
else
  say "Left the app as it was (on-device demo account)."
fi

echo
echo "Done. The database and the first functions are online. Next steps are in ios/README.md under \"Using a real Supabase project\" and \"Turning on…\"."
