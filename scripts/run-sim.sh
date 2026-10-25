#!/bin/bash
# Builds the Debug app for one simulator and runs it on the stub provider with
# in-memory stores: channels, a guide and movies (Apple's public HLS samples)
# with no login and no iCloud.
#
#   scripts/run-sim.sh "iPhone Duo"
#   scripts/run-sim.sh "iPhone 18 Pro" -AppleLanguages "(fr)"   # extra launch arguments go to the app
#   CONSOLE=YES scripts/run-sim.sh "iPhone Duo"                 # stay attached, printing the app's output
#
# The simulator is booted if it isn't already, and a booted one of that name
# is preferred over others (scripts/pick-simulator.sh); Device Hub (Xcode 27's
# successor to Simulator.app) is brought up to show it. The app is Debug's own,
# com.bhavikjain.hearth.dev ("Hearth Dev"), so it never shares a container
# with the TestFlight app. DerivedData is build/DerivedData (DERIVED_DATA
# overrides it), shared with the other scripts; the build log goes to
# build/logs/run-sim.log.
#
# iPhone Duo is on the iOS 27.1 runtime. Open, close and rotate it from
# Device Hub; simctl has no hinge command.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DERIVED_DATA=${DERIVED_DATA:-$ROOT/build/DerivedData}
RELEASE_BUNDLE_ID=com.bhavikjain.hearth

die() { echo "error: $*" >&2; exit 1; }

if [[ $# -lt 1 || $1 == -h || $1 == --help ]]; then
    echo "usage: scripts/run-sim.sh \"<simulator name>\" [launch arguments…]" >&2
    echo "  e.g. scripts/run-sim.sh \"iPhone Duo\"; CONSOLE=YES attaches to the app's output" >&2
    exit 2
fi
name=$1
shift

command -v xcodegen > /dev/null || die "xcodegen isn't installed: brew install xcodegen"
udid=$("$ROOT/scripts/pick-simulator.sh" "$name") || exit 1

cd "$ROOT"
mkdir -p build/logs
log="$ROOT/build/logs/run-sim.log"

echo "Generating Hearth.xcodeproj…"
xcodegen generate --quiet

echo "Building Hearth (Debug) for $name… (log: ${log#"$ROOT"/})"
# Signed the way Xcode signs any simulator build: no Apple ID or profile
# needed, which is how CI builds it too. The architecture is named because a
# simulator is listed once per architecture, and xcodebuild otherwise warns
# that the destination is ambiguous and may pick the Rosetta one.
if ! xcodebuild build \
        -project Hearth.xcodeproj \
        -scheme Hearth \
        -configuration Debug \
        -destination "platform=iOS Simulator,id=$udid,arch=$(uname -m)" \
        -derivedDataPath "$DERIVED_DATA" > "$log" 2>&1; then
    grep -E "(^|[[:space:]])error:|\*\* BUILD FAILED \*\*" "$log" | awk '!seen[$0]++' | tail -30 >&2 || tail -40 "$log" >&2
    die "the build failed. Full log: ${log#"$ROOT"/}"
fi

app="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Hearth.app"
[[ -d $app ]] || die "no app at $app"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
# Debug on the release id shared the TestFlight app's container in Multitrack
# and crashed TestFlight three times; project.yml gives Debug its own.
[[ $bundle_id != "$RELEASE_BUNDLE_ID" ]] || die "the Debug build has the release bundle id; project.yml's Debug config should make it $RELEASE_BUNDLE_ID.dev"

echo "Booting the simulator if needed…"
xcrun simctl bootstatus "$udid" -b > /dev/null

# Shows the simulator. Xcode 27 replaced Simulator.app with Device Hub (in
# Xcode.app/Contents/Applications, where iPhone Duo's fold controls live), so
# `open -a Simulator` finds nothing there; older Xcodes still have Simulator.
# Only a convenience: the app runs on the booted simulator either way.
developer_dir=$(xcode-select -p)
if [[ -d $developer_dir/../Applications/DeviceHub.app ]]; then
    open -a "$developer_dir/../Applications/DeviceHub.app" \
        || echo "warning: couldn't open Device Hub; the app still runs on the booted simulator." >&2
elif [[ -d $developer_dir/Applications/Simulator.app ]]; then
    open -a "$developer_dir/Applications/Simulator.app" --args -CurrentDeviceUDID "$udid" \
        || echo "warning: couldn't open Simulator; the app still runs on the booted simulator." >&2
fi

echo "Installing $bundle_id…"
xcrun simctl install "$udid" "$app"

[[ $name != "iPhone Duo" ]] || echo "Open, close and rotate the iPhone Duo from Device Hub."
args=(-StubProvider YES -InMemoryStores YES "$@")
echo "Launching with ${args[*]}"
if [[ ${CONSOLE:-NO} == YES ]]; then
    echo "(attached: Ctrl-C quits the app)"
    xcrun simctl launch --console-pty --terminate-running-process "$udid" "$bundle_id" "${args[@]}"
else
    xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" "${args[@]}" > /dev/null
    echo "Running. CONSOLE=YES keeps the terminal attached to the app's output."
fi
