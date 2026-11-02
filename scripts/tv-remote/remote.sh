#!/bin/bash
# The Apple TV simulator's remote, for what the Claude simulator tool can't
# press (Menu) and what unit tests can't see (where focus goes, what back does).
#
#   scripts/tv-remote/remote.sh press "down,select,wait,menu" [screenshot folder]
#   scripts/tv-remote/remote.sh check [one flow, like testAMoviesPageSpansTheScreen]
#
# press drives whatever is on screen, one comma-separated step at a time: up,
# down, left, right, select, hold, menu, playpause, wait (1 s), shot. It prints what
# holds focus after each, and stops if the app leaves the foreground: Menu at
# the tab bar quits to the TV's home screen, as on any tvOS app. Screenshots are
# 3840x2160; shrink them with `sips -Z 1280` before reading them.
#
# check runs the back, focus and layout flows (Sources/TVFlows.swift) on the demo,
# then launches the app with its real stores and checks they are in Caches, the
# one place a real Apple TV lets it write. The simulator doesn't enforce that
# rule, so this is what catches a store moving back out.
#
# Install the app first: scripts/run-tv.sh. Simulator: TV_SIM (a name, default
# "Apple TV 4K (3rd generation)"). Everything generated stays outside the repo,
# in TV_REMOTE_WORK.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${TV_REMOTE_WORK:-$HOME/Library/Developer/Xcode/DerivedData/Hearth-tvremote}
NAME=${TV_SIM:-"Apple TV 4K (3rd generation)"}
APP=com.bhavikjain.hearth.dev

die() { echo "error: $*" >&2; exit 1; }

usage() {
    echo "usage: scripts/tv-remote/remote.sh press \"<steps>\" [screenshot folder]" >&2
    echo "       scripts/tv-remote/remote.sh check [flow]" >&2
    exit 2
}

[[ $# -ge 1 ]] || usage
command=$1
shift

# Device names hold parentheses, so match the whole name before the UDID. A
# booted one first.
udid=$(xcrun simctl list devices available | sed -nE "s/^ +$(printf '%s' "$NAME" | sed 's/[()]/\\&/g') \(([0-9A-Fa-f-]{36})\) \(Booted\).*/\1/p" | head -1)
[[ -n $udid ]] || udid=$(xcrun simctl list devices available | sed -nE "s/^ +$(printf '%s' "$NAME" | sed 's/[()]/\\&/g') \(([0-9A-Fa-f-]{36})\) .*/\1/p" | tail -1)
[[ -n $udid ]] || die "no available simulator named \"$NAME\". Install the runtime with: xcodebuild -downloadPlatform tvOS"
xcrun simctl boot "$udid" 2> /dev/null || true
xcrun simctl bootstatus "$udid" > /dev/null
xcrun simctl get_app_container "$udid" "$APP" > /dev/null 2>&1 || die "Hearth Dev isn't on this simulator. Run scripts/run-tv.sh first."

destination="platform=tvOS Simulator,id=$udid"

build() {
    mkdir -p "$WORK"
    xcodegen generate --quiet --spec "$HERE/project.yml" --project "$WORK"
    xcodebuild build-for-testing -project "$WORK/HearthTVRemote.xcodeproj" -scheme TVRemote \
        -destination "$destination" -derivedDataPath "$WORK/DerivedData" -quiet
}

run_tests() {
    local only=$1
    xcodebuild test-without-building -project "$WORK/HearthTVRemote.xcodeproj" -scheme TVRemote \
        -destination "$destination" -derivedDataPath "$WORK/DerivedData" \
        -only-testing:"TVRemoteTests/$only" -resultBundlePath "$WORK/results-$$.xcresult" 2>&1
    local status=$?
    rm -rf "$WORK/results-$$.xcresult"
    return $status
}

check_stores() {
    local data marker
    data=$(xcrun simctl get_app_container "$udid" "$APP" data)
    marker=$WORK/stores-marker
    touch "$marker"
    sleep 1
    xcrun simctl terminate "$udid" "$APP" 2> /dev/null || true
    xcrun simctl launch "$udid" "$APP" > /dev/null

    local waited=0
    until [[ -f $data/Library/Caches/Household.sqlite && -f $data/Library/Caches/Catalog/Catalog.sqlite ]]; do
        sleep 1
        waited=$((waited + 1))
        [[ $waited -lt 30 ]] || die "the household and catalog stores never appeared in Caches"
    done
    sleep 2
    local outside
    outside=$(find "$data/Library/Application Support" "$data/Documents" -name '*.sqlite*' -newer "$marker" 2> /dev/null || true)
    [[ -z $outside ]] || die "a store was written where a real Apple TV refuses it: $outside"
    xcrun simctl terminate "$udid" "$APP" 2> /dev/null || true
    echo "Stores: the household and catalog open from Caches, and nothing else was written."
}

case $command in
    press)
        [[ $# -ge 1 ]] || usage
        steps=$1
        out=${2:-}
        if [[ -n $out ]]; then
            mkdir -p "$out"
            out=$(cd "$out" && pwd)
        fi
        build
        TEST_RUNNER_STEPS=$steps TEST_RUNNER_OUT=$out run_tests Remote/testDrive \
            | grep -E '^STEP |error:|\*\* TEST' | grep -v 'TEST EXECUTE SUCCEEDED' || true
        ;;
    check)
        build
        set +e
        flow=${1:-}
        output=$(run_tests "TVFlows${flow:+/$flow}")
        status=$?
        set -e
        echo "$output" | grep -E "Test Case .* (passed|failed)|error:" | sed -E 's/^.*(Test Case )/\1/' || true
        # The stores are checked either way: a failed flow shouldn't hide one
        # that moved. One flow on its own is someone working on that flow.
        [[ -n $flow ]] || check_stores
        [[ $status -eq 0 ]] || die "the flows failed"
        ;;
    *)
        usage
        ;;
esac
