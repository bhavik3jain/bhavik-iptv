#!/bin/bash
# Sends the household model's CloudKit schema to iCloud *Development*: the
# first half of the schema ritual (README → Release, CLAUDE.md → Household
# store). The second half, Deploy Schema Changes to Production, exists only in
# the CloudKit Console; there's no API for it, and GitHub runners can't sign
# in to iCloud, so neither half can be a workflow.
#
#   scripts/cloudkit/init-schema.sh                           # a signed Debug build of the Mac app (default)
#   scripts/cloudkit/init-schema.sh --simulator               # a simulator: iPhone Duo, else the newest iPhone
#   scripts/cloudkit/init-schema.sh --simulator "iPhone 18 Pro"
#
# Run it after adding an entity or attribute to HouseholdModel, before any
# TestFlight build that ships the change. Production never creates record
# types on its own, so a build shipped before the deploy saves locally and
# never syncs. Encrypted attributes (logins) must be marked before the first
# Production deploy: that can't be added later.
#
# Both modes launch the Debug app with -InitializeCloudKitSchema YES, a launch
# that opens only throwaway in-memory stores, never the real ones, and pushes
# the schema with Core Data's initializeCloudKitSchema().
#
# Mac mode. Builds the Mac app unsigned and signs it by hand with this Mac's
# Apple Development certificate and a Mac development profile, the way
# Multitrack's script does: Xcode refuses an Xcode-managed profile under
# manual signing ("is Xcode managed, but signing settings require a manually
# managed profile"), and a Mac without an Apple ID in Xcode can't sign
# automatically. The profile must be for com.bhavikjain.hearth.dev or
# com.bhavikjain.hearth, list this Mac, and carry iCloud; building the Mac app
# once in Xcode, signed in, makes one. A release-id profile shares the
# TestFlight app's sandbox container, which is safe for this launch only,
# since it never opens a real store. This Mac must be signed in to iCloud.
#
# Simulator mode. Builds the Debug app for the simulator the way Xcode always
# does (no Apple ID needed; the entitlements are embedded), installs it and
# launches it there. The simulator must be signed in to an Apple Account
# (Settings in the simulator).
#
# What the script expects of the app (App/Sources, ported from Multitrack's
# CloudKitSchemaInitializer): on -InitializeCloudKitSchema YES it prints
#   [CloudKitSchemaInitializer] Schema sent to Development: <record types>
# or
#   [CloudKitSchemaInitializer] Failed: <error>
# Optionally, -SchemaPass list prints
#   [CloudKitSchemaInitializer] Passes: <name> <name> …
# and -SchemaPass <name> runs only that pass; the script then runs each pass
# in a process of its own (Multitrack's throwaway stores, kept open together,
# queued behind each other's downloads until Core Data timed out). An app that
# ignores -SchemaPass runs everything on the first launch, which also works.
#
# Overrides: SIGN_IDENTITY="Apple Development: …", PROFILE=/path/to/x.provisionprofile,
# TIMEOUT=seconds per launch (default 300), WORK=build folder (deleted on exit).

set -euo pipefail

TEAM=Y4M3S6H4NK
RELEASE_ID=com.bhavikjain.hearth
DEV_ID=com.bhavikjain.hearth.dev
CONTAINER=iCloud.com.bhavikjain.hearth
MARK='[CloudKitSchemaInitializer]'
TIMEOUT=${TIMEOUT:-300}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=${WORK:-$HOME/Library/Developer/Xcode/DerivedData/Hearth-schema-init}
LOG="$WORK/run.log"
# WORK is deleted on exit, so a slip like WORK=~ must not get that far.
case "${WORK%/}" in
    ""|/|"$HOME"|"$ROOT"|/tmp|/private/tmp) echo "error: WORK=$WORK would be deleted on exit; give it a folder of its own" >&2; exit 2 ;;
esac

MODE=mac
SIMULATOR=""
case "${1:-}" in
    "") ;;
    --simulator) MODE=simulator; SIMULATOR=${2:-} ;;
    -h|--help)
        echo "usage: scripts/cloudkit/init-schema.sh [--simulator [\"<simulator name>\"]]" >&2
        exit 2 ;;
    *) echo "error: unknown argument '$1' (see the header of this script)" >&2; exit 2 ;;
esac

APP_PID=""
UDID=""
BUNDLE_ID=""

cleanup() {
    if [[ -n $APP_PID ]]; then kill "$APP_PID" 2>/dev/null || true; fi
    if [[ -n $UDID && -n $BUNDLE_ID ]]; then xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

die() { echo "error: $*" >&2; exit 1; }

command -v xcodegen > /dev/null || die "xcodegen isn't installed: brew install xcodegen"
mkdir -p "$WORK"
cd "$ROOT"
xcodegen generate --quiet

# Builds with the arguments given, its output in $WORK/build.log; on failure
# prints the errors and stops.
build() {
    xcodebuild build -project Hearth.xcodeproj -configuration Debug -derivedDataPath "$WORK/dd" "$@" \
        > "$WORK/build.log" 2>&1 && return 0
    grep -E "(^|[[:space:]])error:" "$WORK/build.log" | awk '!seen[$0]++' | tail -30 >&2 || tail -40 "$WORK/build.log" >&2
    die "the build failed"
}

# MARK: - Mac: signing identity, profile, build, signature

prepare_mac() {
    if [[ -z ${SIGN_IDENTITY:-} ]]; then
        SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
    fi
    [[ -n $SIGN_IDENTITY ]] || die "no Apple Development certificate in the keychain. Xcode → Settings → Accounts → Manage Certificates makes one."

    local this_mac
    this_mac=$(system_profiler SPHardwareDataType | awk -F': ' '/Provisioning UDID/ { print $2 }')

    # Prints "<bundle id> <path>" for the best Mac development profile: the
    # .dev app id first, then the release one; only profiles that list this
    # Mac, carry iCloud and haven't expired.
    find_profile() {
        local best_release="" best_dev="" plist dir file app expiry
        plist=$(mktemp)
        for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
            [[ -d $dir ]] || continue
            for file in "$dir"/*.provisionprofile; do
                [[ -f $file ]] || continue
                security cms -D -i "$file" > "$plist" 2>/dev/null || continue
                app=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null) || continue
                /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-services' "$plist" > /dev/null 2>&1 || continue
                /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$plist" 2>/dev/null | grep -q "$this_mac" || continue
                expiry=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$plist")
                [[ $(date -j -f '%a %b %d %T %Z %Y' "$expiry" +%s 2>/dev/null || echo 0) -gt $(date +%s) ]] || continue
                case "$app" in
                    "$TEAM.$DEV_ID") best_dev=$file ;;
                    "$TEAM.$RELEASE_ID") best_release=$file ;;
                esac
            done
        done
        rm -f "$plist"
        if [[ -n $best_dev ]]; then echo "$DEV_ID $best_dev"
        elif [[ -n $best_release ]]; then echo "$RELEASE_ID $best_release"
        fi
    }

    if [[ -n ${PROFILE:-} ]]; then
        [[ -f $PROFILE ]] || die "PROFILE doesn't name a file"
        BUNDLE_ID=$(security cms -D -i "$PROFILE" | plutil -extract 'Entitlements.com\.apple\.application-identifier' raw - | sed "s/^$TEAM\.//")
    else
        read -r BUNDLE_ID PROFILE < <(find_profile) || true
    fi
    [[ -n ${PROFILE:-} && -f $PROFILE ]] \
        || die "no Mac development profile for $DEV_ID or $RELEASE_ID that lists this Mac and carries iCloud. Building the Mac app once in Xcode, signed in, makes one."
    case "$BUNDLE_ID" in
        "$DEV_ID"|"$RELEASE_ID") ;;
        *) die "the profile is for $BUNDLE_ID, not $DEV_ID or $RELEASE_ID" ;;
    esac

    echo "Signing as:  $SIGN_IDENTITY"
    echo "Profile:     $(basename "$PROFILE") ($BUNDLE_ID)"
    [[ $BUNDLE_ID != "$RELEASE_ID" ]] || echo "             release app id: fine for this launch only, see the header"

    echo "Building the Mac app (Debug, unsigned)…"
    build -scheme Hearth-macOS -destination "platform=macOS,arch=$(uname -m)" \
        PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGNING_ALLOWED=NO

    APP="$WORK/dd/Build/Products/Debug/Hearth.app"
    [[ -d $APP ]] || die "no app at $APP"
    EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")

    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    local entitlements="$WORK/app.entitlements"
    sed -e "s/\$(TeamIdentifierPrefix)\$(CFBundleIdentifier)/$TEAM.$BUNDLE_ID/g" \
        -e "s/\$(TeamIdentifierPrefix)/$TEAM./g" \
        -e "s/\$(CFBundleIdentifier)/$BUNDLE_ID/g" \
        App/Resources/App-macOS.entitlements > "$entitlements"
    if grep -q '\$(' "$entitlements"; then
        die "App-macOS.entitlements has a \$(…) variable this script doesn't fill in: $(grep -o '\$([A-Za-z_]*)' "$entitlements" | sort -u | tr '\n' ' ')"
    fi
    # Restricted entitlements (iCloud, push) are only honoured when the
    # signature also names the app and team, as Xcode's own signing does.
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" \
        -c "Add :com.apple.developer.team-identifier string $TEAM" "$entitlements"

    # Nested code first (VLCKit's framework and its dylibs), then the app.
    TEAM=$TEAM "$ROOT/scripts/codesign-app.sh" --identity "$SIGN_IDENTITY" "$APP" "$entitlements" 2> "$WORK/sign.log" \
        || { cat "$WORK/sign.log" >&2; die "signing the app failed"; }
}

# MARK: - Simulator: build, boot, install

prepare_simulator() {
    if [[ -n $SIMULATOR ]]; then
        UDID=$("$ROOT/scripts/pick-simulator.sh" "$SIMULATOR") || exit 1
    else
        UDID=$("$ROOT/scripts/pick-simulator.sh") || exit 1
    fi

    echo "Building the app (Debug) for the simulator…"
    build -scheme Hearth -destination "platform=iOS Simulator,id=$UDID,arch=$(uname -m)"

    APP="$WORK/dd/Build/Products/Debug-iphonesimulator/Hearth.app"
    [[ -d $APP ]] || die "no app at $APP"
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")

    echo "Booting the simulator if needed…"
    xcrun simctl bootstatus "$UDID" -b > /dev/null
    xcrun simctl install "$UDID" "$APP"
}

# MARK: - Run

# Starts the app with -InitializeCloudKitSchema YES plus "$@", output in $LOG.
#
# -ApplePersistenceIgnoreState (Mac): with the release app id, Multitrack's run
# inherited the TestFlight app's saved window state and opened no window at
# all, and the initializer runs from its window, so nothing happened.
# NSUnbufferedIO: the result is print()ed, and a pipe to a file held it back
# until exit. The simulator passes SIMCTL_CHILD_ variables to the app.
start_app() {
    if [[ $MODE == mac ]]; then
        NSUnbufferedIO=YES "$APP/Contents/MacOS/$EXECUTABLE" \
            -InitializeCloudKitSchema YES -ApplePersistenceIgnoreState YES "$@" > "$LOG" 2>&1 &
    else
        SIMCTL_CHILD_NSUnbufferedIO=YES xcrun simctl launch --console --terminate-running-process \
            "$UDID" "$BUNDLE_ID" -InitializeCloudKitSchema YES "$@" > "$LOG" 2>&1 &
    fi
    APP_PID=$!
    disown "$APP_PID"   # no "Terminated: 15" from the shell when it's ended
}

stop_app() {
    [[ -n $APP_PID ]] || return 0
    kill "$APP_PID" 2>/dev/null || true
    if [[ $MODE == simulator ]]; then xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true; fi
    # Gone before the next launch, so its throwaway store is closed when that
    # one clears the old folder.
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
    APP_PID=""
}

# Launches the app with "$@", waits (at most TIMEOUT seconds) for its result
# in $LOG, then quits it. Returns 0 when the schema was sent (or, for
# -SchemaPass list, the passes were listed), 1 when the run failed, 2 when it
# never answered.
launch() {
    start_app "$@"
    local result=2 elapsed
    for ((elapsed = 0; elapsed < TIMEOUT; elapsed += 2)); do
        if grep -qF "$MARK Schema sent to Development" "$LOG"; then result=0; break; fi
        # The app stays open after listing, so the list ends the wait.
        if grep -qF "$MARK Passes:" "$LOG"; then result=0; break; fi
        # A moment more, so the lines after the failure (CloudKit's own
        # errors) reach the log too.
        if grep -qF "$MARK Failed" "$LOG"; then sleep 2; result=1; break; fi
        kill -0 "$APP_PID" 2>/dev/null || break
        sleep 2
    done
    stop_app
    return $result
}

# The whole failure, not just its tagged first line: Core Data's error 134060
# lists CloudKit's own errors on the lines after it, and those say what went
# wrong.
show_failure() {
    if grep -qF "$MARK Failed" "$LOG"; then
        sed -n "/$(printf '%s' "$MARK" | sed 's/[][]/\\&/g') Failed/,\$p" "$LOG" | grep -v 'CoreData: debug\|CoreData: annotation' | head -60 >&2
    else
        grep -v 'CoreData: debug\|CoreData: annotation' "$LOG" | tail -40 >&2 || true
    fi
}

no_answer() {
    if [[ $MODE == mac ]]; then
        die "$1 got no answer after ${TIMEOUT}s. Is this Mac signed in to iCloud (System Settings → Apple Account)? Does the app handle -InitializeCloudKitSchema (see this script's header)?"
    else
        die "$1 got no answer after ${TIMEOUT}s. Is the simulator signed in to an Apple Account (its Settings app)? Does the app handle -InitializeCloudKitSchema (see this script's header)?"
    fi
}

# Prints the app's report lines, indented, minus the ones the script reads.
report() {
    grep -F "$MARK" "$LOG" | grep -v 'Passes:' | sed "s/^/    /" || true
}

if [[ $MODE == mac ]]; then prepare_mac; else prepare_simulator; fi

echo "Sending the schema to $CONTAINER (Development)…"
outcome=0
launch -SchemaPass list || outcome=$?
passes=$(sed -n "s/^.*\[CloudKitSchemaInitializer\] Passes: //p" "$LOG" | head -1)

if [[ -n $passes ]]; then
    # One process per pass, each retried once: a pass that timed out usually
    # goes through on a fresh launch.
    for pass in $passes; do
        echo "  $pass…"
        outcome=0
        launch -SchemaPass "$pass" || outcome=$?
        if [[ $outcome -ne 0 ]]; then
            echo "  $pass didn't finish; trying it once more…"
            outcome=0
            launch -SchemaPass "$pass" || outcome=$?
        fi
        if [[ $outcome -ne 0 ]]; then
            show_failure
            [[ $outcome -ne 2 ]] || no_answer "the $pass pass"
            die "the $pass pass failed; nothing else was changed in CloudKit"
        fi
        report
    done
elif [[ $outcome -eq 0 ]]; then
    # An app without passes did the whole run on that first launch.
    report
else
    show_failure
    [[ $outcome -ne 2 ]] || no_answer "the run"
    die "the run failed; nothing was changed in CloudKit"
fi

echo
echo "Done. Next, in the CloudKit Console (https://icloud.developer.apple.com):"
echo "  1. $CONTAINER → Development → Schema → Record Types: check the new record"
echo "     types and fields are there (Core Data's are named CD_<Entity>), and that"
echo "     logins are encrypted fields."
echo "  2. Deploy Schema Changes… → Production, before any TestFlight build ships them."
