#!/bin/bash
# Builds the Debug Apple TV app (Hearth-tvOS) and runs it on an Apple TV
# simulator on the stub provider with in-memory stores: channels, a guide and
# movies (Apple's public HLS samples) with no login and no iCloud.
#
#   scripts/run-tv.sh                                    # Apple TV 4K (3rd generation)
#   scripts/run-tv.sh "Apple TV 4K (3rd generation) (at 1080p)"
#   scripts/run-tv.sh "" -SelectProfile Bhavik -OpenTab live   # extra launch arguments go to the app
#   CONSOLE=YES scripts/run-tv.sh                        # stay attached, printing the app's output
#   REAL=YES scripts/run-tv.sh                           # no demo: the household on disk
#
# REAL=YES drops -StubProvider and -InMemoryStores. The TV doesn't add
# sources itself (that is done from an iPhone, iPad or Mac in the same iCloud
# household), so on a simulator with no iCloud account a REAL run shows the
# "Add a source from your iPhone" state; sign the simulator in to iCloud to
# see a real household arrive.
#
# The Apple TV simulator needs the tvOS runtime: `xcodebuild -downloadPlatform
# tvOS` installs it. The simulator is booted if it isn't already; the app is
# Debug's own, com.bhavikjain.hearth.dev ("Hearth Dev"). DerivedData is
# build/DerivedData (DERIVED_DATA overrides it), shared with the other
# scripts; the build log goes to build/logs/run-tv.log.
#
# The remote in Device Hub (or the Mac keyboard with the simulator in front):
# arrows move focus, Return selects, Escape is Menu, Space is Play/Pause.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DERIVED_DATA=${DERIVED_DATA:-$ROOT/build/DerivedData}
RELEASE_BUNDLE_ID=com.bhavikjain.hearth

die() { echo "error: $*" >&2; exit 1; }

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    echo "usage: scripts/run-tv.sh [\"<Apple TV simulator name>\"] [launch arguments…]" >&2
    exit 2
fi
name=${1:-"Apple TV 4K (3rd generation)"}
[[ -n $name ]] || name="Apple TV 4K (3rd generation)"
[[ $# -gt 0 ]] && shift

command -v xcodegen > /dev/null || die "xcodegen isn't installed: brew install xcodegen"

# The UDID of an available device of that name on the newest tvOS runtime, a
# booted one first. The text listing is parsed by the UDID's shape, since
# device names hold parentheses.
pick_tv() {
    local runtime="" line best="" best_runtime="" booted=""
    while IFS= read -r line; do
        if [[ $line =~ ^--\ tvOS\ ([0-9.]+)\ --$ ]]; then
            runtime=${BASH_REMATCH[1]}
        elif [[ $line =~ ^--\  ]]; then
            runtime=""
        elif [[ -n $runtime && $line =~ ^\ +(.+)\ \(([0-9A-Fa-f-]{36})\)\ \(([A-Za-z ]+)\) ]]; then
            [[ ${BASH_REMATCH[1]} == "$name" ]] || continue
            [[ ${BASH_REMATCH[3]} == Booted ]] && booted=${BASH_REMATCH[2]}
            if [[ -z $best_runtime ]] || [[ $(printf '%s\n%s\n' "$best_runtime" "$runtime" | sort -V | tail -1) == "$runtime" ]]; then
                best=${BASH_REMATCH[2]}
                best_runtime=$runtime
            fi
        fi
    done < <(xcrun simctl list devices available)
    echo "${booted:-$best}"
}

udid=$(pick_tv)
if [[ -z $udid ]]; then
    echo "Apple TV simulators installed:" >&2
    xcrun simctl list devices available | sed -n '/^-- tvOS/,/^-- [^t]/p' >&2
    die "no available simulator named \"$name\" on a tvOS runtime. Install the runtime with: xcodebuild -downloadPlatform tvOS"
fi

cd "$ROOT"
mkdir -p build/logs
log="$ROOT/build/logs/run-tv.log"

echo "Generating Hearth.xcodeproj…"
xcodegen generate --quiet

echo "Building Hearth-tvOS (Debug) for $name… (log: ${log#"$ROOT"/})"
# Signed the way Xcode signs any simulator build, so the iCloud entitlement
# is there for REAL runs (an unsigned build's CloudKit store crashes at
# launch; only -InMemoryStores hides that).
if ! xcodebuild build \
        -project Hearth.xcodeproj \
        -scheme Hearth-tvOS \
        -configuration Debug \
        -destination "platform=tvOS Simulator,id=$udid,arch=$(uname -m)" \
        -derivedDataPath "$DERIVED_DATA" > "$log" 2>&1; then
    grep -E "(^|[[:space:]])error:|\*\* BUILD FAILED \*\*" "$log" | awk '!seen[$0]++' | tail -30 >&2 || tail -40 "$log" >&2
    die "the build failed. Full log: ${log#"$ROOT"/}"
fi

app="$DERIVED_DATA/Build/Products/Debug-appletvsimulator/Hearth.app"
[[ -d $app ]] || die "no app at $app"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
[[ $bundle_id != "$RELEASE_BUNDLE_ID" ]] || die "the Debug build has the release bundle id; project.yml's Debug config should make it $RELEASE_BUNDLE_ID.dev"

echo "Booting the simulator if needed…"
xcrun simctl bootstatus "$udid" -b > /dev/null

# Shows the simulator in Device Hub (Xcode 27) or Simulator (older Xcodes);
# only a convenience, the app runs on the booted simulator either way.
developer_dir=$(xcode-select -p)
if [[ -d $developer_dir/../Applications/DeviceHub.app ]]; then
    open -a "$developer_dir/../Applications/DeviceHub.app" \
        || echo "warning: couldn't open Device Hub; the app still runs on the booted simulator." >&2
elif [[ -d $developer_dir/Applications/Simulator.app ]]; then
    open -a "$developer_dir/Applications/Simulator.app" --args -CurrentDeviceUDID "$udid" \
        || echo "warning: couldn't open Simulator; the app still runs on the booted simulator." >&2
fi

echo "Installing $bundle_id… (VLCKit makes the app large; this takes a moment)"
xcrun simctl install "$udid" "$app"

if [[ ${REAL:-NO} == YES ]]; then
    args=("$@")
else
    args=(-StubProvider YES -InMemoryStores YES "$@")
fi
echo "Launching with ${args[*]-(no arguments)}"
if [[ ${CONSOLE:-NO} == YES ]]; then
    echo "(attached: Ctrl-C quits the app)"
    xcrun simctl launch --console-pty --terminate-running-process "$udid" "$bundle_id" ${args[@]+"${args[@]}"}
else
    xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" ${args[@]+"${args[@]}"} > /dev/null
    echo "Running. CONSOLE=YES keeps the terminal attached to the app's output."
fi
