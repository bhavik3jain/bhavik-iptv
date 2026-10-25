#!/bin/bash
# Builds the Debug Mac app and runs it on this Mac with no Apple ID and no
# provisioning profile: unsigned build, then signed ad hoc with
# App/Resources/App-macOS-Local.entitlements, on the stub provider with
# in-memory stores.
#
#   scripts/run-mac-local.sh                          # build, sign, run in the foreground (Ctrl-C quits)
#   scripts/run-mac-local.sh -AppleLanguages "(fr)"   # extra launch arguments go to the app
#   scripts/run-mac-local.sh --no-launch              # build and sign only
#
# Why that entitlements file: an app that claims iCloud without a profile is
# killed at launch (AMFI), so the local one keeps only the sandbox, outgoing
# connections and user-selected files, and the app runs with
# -InMemoryStores YES. iCloud on the Mac needs a profile-signed build; the
# schema script shows how.
#
# The app is Debug's own, com.bhavikjain.hearth.dev ("Hearth Dev"), with its
# own sandbox container. DerivedData is build/DerivedData (DERIVED_DATA
# overrides it); the build log goes to build/logs/run-mac-local.log. The app
# runs from the terminal, so its output (print, -SourceProbe) shows here.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DERIVED_DATA=${DERIVED_DATA:-$ROOT/build/DerivedData}
RELEASE_BUNDLE_ID=com.bhavikjain.hearth
ENTITLEMENTS="$ROOT/App/Resources/App-macOS-Local.entitlements"

die() { echo "error: $*" >&2; exit 1; }

LAUNCH=YES
if [[ ${1:-} == --no-launch ]]; then
    LAUNCH=NO
    shift
elif [[ ${1:-} == -h || ${1:-} == --help ]]; then
    echo "usage: scripts/run-mac-local.sh [--no-launch] [launch arguments…]" >&2
    exit 2
fi

command -v xcodegen > /dev/null || die "xcodegen isn't installed: brew install xcodegen"
[[ -f $ENTITLEMENTS ]] || die "missing ${ENTITLEMENTS#"$ROOT"/}"

cd "$ROOT"
mkdir -p build/logs
log="$ROOT/build/logs/run-mac-local.log"

echo "Generating Hearth.xcodeproj…"
xcodegen generate --quiet

echo "Building Hearth-macOS (Debug, unsigned)… (log: ${log#"$ROOT"/})"
if ! xcodebuild build \
        -project Hearth.xcodeproj \
        -scheme Hearth-macOS \
        -configuration Debug \
        -destination "platform=macOS,arch=$(uname -m)" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO > "$log" 2>&1; then
    grep -E "(^|[[:space:]])error:|\*\* BUILD FAILED \*\*" "$log" | awk '!seen[$0]++' | tail -30 >&2 || tail -40 "$log" >&2
    die "the build failed. Full log: ${log#"$ROOT"/}"
fi

app="$DERIVED_DATA/Build/Products/Debug/Hearth.app"
[[ -d $app ]] || die "no app at $app"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
# With the release id the app would open the TestFlight app's sandbox
# container; Multitrack crashed TestFlight that way three times.
[[ $bundle_id != "$RELEASE_BUNDLE_ID" ]] || die "the Debug build has the release bundle id; project.yml's Debug config should make it $RELEASE_BUNDLE_ID.dev"

echo "Signing ad hoc with ${ENTITLEMENTS#"$ROOT"/}…"
# Nested code first (VLCKit's framework, any dylib): codesign refuses a bundle
# whose nested code is unsigned. No hardened runtime: it's for distribution,
# and its library validation would refuse ad hoc frameworks, which carry no
# team id.
find "$app/Contents" \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' \) -prune -print0 \
    | xargs -0 -I{} codesign --force --sign - --timestamp=none {} 2>> "$log" \
    || die "signing the app's frameworks failed; see ${log#"$ROOT"/}"
codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$app" 2>> "$log" \
    || die "signing the app failed; see ${log#"$ROOT"/}"
codesign --verify --strict "$app" 2>> "$log" || die "the signature doesn't verify; see ${log#"$ROOT"/}"

if [[ $LAUNCH == NO ]]; then
    echo "Built and signed: ${app#"$ROOT"/} ($bundle_id). Not launched (--no-launch)."
    exit 0
fi

args=(-StubProvider YES -InMemoryStores YES "$@")
echo "Running $bundle_id with ${args[*]} (Ctrl-C quits)"
exec "$app/Contents/MacOS/$executable" "${args[@]}"
