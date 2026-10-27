#!/bin/bash
# Prints the UDID of an available iOS simulator. Used by the Tests workflow,
# scripts/run-sim.sh and scripts/cloudkit/init-schema.sh.
#
#   scripts/pick-simulator.sh                # an iPhone on the newest runtime, never the iPhone Duo
#   scripts/pick-simulator.sh "iPhone Duo"   # that device: a booted one first, else the newest runtime's
#
# Only the UDID goes to stdout, so `udid=$(scripts/pick-simulator.sh)` works;
# what was chosen goes to stderr. When nothing matches it lists what is
# installed and exits 1. It never boots, creates or changes a simulator.
#
# Why not a pinned name: runner images change their simulator line-up, and
# iPhone Duo exists only on the iOS 27.1 runtime, which an image may not have.
# A pinned model that isn't installed fails CI before anything is built.

set -euo pipefail

wanted=${1:-}

# The text listing is parsed rather than the JSON one so this needs nothing
# beyond bash. Device names can hold parentheses ("iPad Pro 13-inch (M5)"),
# so the UDID is matched by its shape, then the state after it.
runtime_header='^-- iOS ([0-9.]+) --$'
other_header='^-- '
device_line='^ +(.+) \(([0-9A-Fa-f-]{36})\) \(([A-Za-z ]+)\)'

# One row per available iOS device, in listing order:
# "<runtime version>|<state>|<udid>|<name>". watchOS, tvOS and visionOS
# devices are skipped.
rows() {
    local runtime="" line
    while IFS= read -r line; do
        if [[ $line =~ $runtime_header ]]; then
            runtime=${BASH_REMATCH[1]}
        elif [[ $line =~ $other_header ]]; then
            runtime=""
        elif [[ -n $runtime && $line =~ $device_line ]]; then
            echo "$runtime|${BASH_REMATCH[3]}|${BASH_REMATCH[2]}|${BASH_REMATCH[1]}"
        fi
    done < <(xcrun simctl list devices available)
}

# From rows on stdin, the one on the newest runtime (the first listed there
# when several are). With "booted" as $1 a booted one wins, so a run script
# reuses the simulator already open on screen.
best() {
    local all booted
    all=$(cat)
    [[ -n $all ]] || return 0
    if [[ ${1:-} == booted ]]; then
        booted=$(grep '|Booted|' <<< "$all" || true)
        [[ -z $booted ]] || all=$booted
    fi
    local newest
    newest=$(cut -d'|' -f1 <<< "$all" | sort -V | tail -1)
    awk -F'|' -v runtime="$newest" '$1 == runtime { print; exit }' <<< "$all"
}

all_rows=$(rows)
if [[ -n $wanted ]]; then
    pick=$(awk -F'|' -v name="$wanted" '$4 == name' <<< "$all_rows" | best booted)
else
    # An iPhone on the newest runtime, booted or not; which model matters
    # less than having one. Never the iPhone Duo unless asked for by name:
    # its simulator can take several minutes to boot the first time (Xcode
    # 27.1 release notes), which Multitrack's CI hit, and the package tests
    # don't depend on the screen. Check the Duo's layouts by running the app
    # on it (scripts/run-sim.sh "iPhone Duo").
    pick=$(awk -F'|' '$4 ~ /^iPhone/ && $4 != "iPhone Duo"' <<< "$all_rows" | best)
fi

if [[ -z $pick ]]; then
    if [[ -n $wanted ]]; then
        echo "error: no available iOS simulator named \"$wanted\"." >&2
    else
        echo "error: no available iPhone simulator." >&2
    fi
    echo "Installed iOS simulators:" >&2
    if [[ -n $all_rows ]]; then
        awk -F'|' '{ printf "  %s (iOS %s, %s)\n", $4, $1, $2 }' <<< "$all_rows" >&2
    else
        echo "  (none: Xcode → Settings → Components installs a runtime, or xcodebuild -downloadPlatform iOS)" >&2
    fi
    exit 1
fi

IFS='|' read -r runtime state udid name <<< "$pick"
echo "Simulator: $name (iOS $runtime, $state) $udid" >&2
echo "$udid"
