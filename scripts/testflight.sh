#!/bin/bash
# Archives Hearth and uploads it to TestFlight from this Mac: the local twin
# of .github/workflows/testflight.yml, for when the repo's testflight
# environment has no secrets yet, or a build is wanted now.
#
#   scripts/testflight.sh ios               # the iPhone and iPad app
#   scripts/testflight.sh mac               # the Mac app
#   scripts/testflight.sh tv                # the Apple TV app
#   scripts/testflight.sh all               # all three: iOS, then Mac, then Apple TV
#   scripts/testflight.sh ios --no-upload   # archive and export into build/, upload nothing
#
# It signs and uploads as one of two identities:
#   - an App Store Connect API key, when ASC_KEY_ID, ASC_ISSUER_ID and
#     ASC_KEY_PATH (the AuthKey_….p8 file) are all set. The key needs the
#     Admin role: with App Manager, cloud-managed distribution signing fails
#     with "Cloud signing permission error".
#   - otherwise the Apple ID signed in to Xcode (Settings → Accounts) as a
#     member of team Y4M3S6H4NK.
#
# BUILD_NUMBER overrides the build number. It defaults to the UTC time as
# yyDDDHHMM (year, day of the year, hour, minute), which only goes up and
# stays under 2^31 — yymmddHHMM (2610251000…) doesn't, and a build number
# component that large risks App Store Connect's validation. Those numbers sit far above the workflow's
# (run number + 100), so after a local upload the workflow relies on the
# export raising its number (Xcode's manageAppVersionAndBuildNumber, left at
# its default) or on its build_number input.
#
# Everything lands under build/ (gitignored): build/testflight/<build>/ holds
# the archives, exports and logs; build/DerivedData is shared with the run
# scripts (DERIVED_DATA overrides it). Secrets are never printed, and nothing
# is uploaded unless every step before it succeeded.
#
# Before a build that changes the household model, run the CloudKit schema
# ritual first (scripts/cloudkit/init-schema.sh, then Deploy Schema Changes to
# Production): a build shipped before that deploy saves locally and never syncs.

set -euo pipefail

TEAM=Y4M3S6H4NK
BUNDLE_ID=com.bhavikjain.hearth
CONTAINER=iCloud.com.bhavikjain.hearth
MIN_XCODE=27.1
ROOT=$(cd "$(dirname "$0")/.." && pwd)

die() { echo "error: $*" >&2; exit 1; }

usage() {
    echo "usage: scripts/testflight.sh ios|mac|tv|all [--no-upload]" >&2
    echo "  Signs with ASC_KEY_ID + ASC_ISSUER_ID + ASC_KEY_PATH when all are set, else the Apple ID in Xcode." >&2
    echo "  BUILD_NUMBER overrides the build number (default: UTC yyDDDHHMM)." >&2
    exit 2
}

# MARK: - Arguments

PLATFORM=""
UPLOAD=YES
for arg in "$@"; do
    case "$arg" in
        ios|mac|tv|all) [[ -z $PLATFORM ]] || usage; PLATFORM=$arg ;;
        --no-upload) UPLOAD=NO ;;
        -h|--help) usage ;;
        *) echo "error: unknown argument '$arg'" >&2; usage ;;
    esac
done
[[ -n $PLATFORM ]] || usage

# MARK: - Tools

command -v xcodebuild > /dev/null || die "xcodebuild not found. Install Xcode $MIN_XCODE and run: sudo xcode-select -s /Applications/Xcode.app"
command -v xcodegen > /dev/null || die "xcodegen isn't installed: brew install xcodegen"

# Hearth needs the iOS 27.1 SDK (iPhone Duo); an older Xcode fails late, in
# the middle of the archive, with errors that don't say so.
xcode_version=$(xcodebuild -version 2>/dev/null | awk 'NR == 1 { print $2 }') \
    || die "xcodebuild can't run; xcode-select points at $(xcode-select -p). Switch to Xcode $MIN_XCODE: sudo xcode-select -s /Applications/Xcode.app"
lowest=$(printf '%s\n%s\n' "$MIN_XCODE" "$xcode_version" | sort -V | head -1)
[[ $lowest == "$MIN_XCODE" ]] \
    || die "Hearth needs Xcode $MIN_XCODE or newer; xcode-select points at Xcode $xcode_version ($(xcode-select -p)). Switch with: sudo xcode-select -s /Applications/Xcode.app"

# MARK: - Identity

# The API key's three settings go together; a partial set is a mistake worth
# stopping for rather than silently falling back to the Xcode account.
AUTH=()
missing=()
for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
    [[ -n ${!name:-} ]] || missing+=("$name")
done
if (( ${#missing[@]} == 0 )); then
    [[ -f $ASC_KEY_PATH && -r $ASC_KEY_PATH ]] || die "ASC_KEY_PATH doesn't name a readable file (it should be the AuthKey_….p8 downloaded from App Store Connect)"
    # Absolute, since everything below runs from the repo root.
    ASC_KEY_PATH="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd)/$(basename "$ASC_KEY_PATH")"
    AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    IDENTITY="App Store Connect API key (id …${ASC_KEY_ID: -4})"
    AUTH_MODE=key
elif (( ${#missing[@]} == 3 )); then
    IDENTITY="the Apple ID signed in to Xcode (Settings → Accounts)"
    AUTH_MODE=xcode
else
    die "ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH go together; missing: ${missing[*]}. Unset all three to sign with the Apple ID in Xcode instead."
fi

# MARK: - Build number and paths

BUILD_NUMBER=${BUILD_NUMBER:-$(date -u +%y%j%H%M)}
build_number_shape='^[0-9]+(\.[0-9]+){0,2}$'
[[ $BUILD_NUMBER =~ $build_number_shape ]] || die "BUILD_NUMBER must be digits, at most three dot-separated numbers; got '$BUILD_NUMBER'"

OUT="$ROOT/build/testflight/$BUILD_NUMBER"
DERIVED_DATA=${DERIVED_DATA:-$ROOT/build/DerivedData}
mkdir -p "$OUT"
cd "$ROOT"

# MARK: - Failures

# The usual reasons an archive or upload fails, in words, after xcodebuild's
# own errors. Matched loosely and only against the log's error lines (a
# successful step's output mentions iCloud and profiles too): Apple rewords
# these messages between Xcode versions.
explain_failure() {
    local log=$1 errors hinted=0
    errors=$(grep -iE "error|failed|denied|refused|invalid|unable|cannot|could not|no accounts|no profiles" "$log" || true)
    says() { grep -qiE "$1" <<< "$errors"; }
    hint() { echo "  → $*" >&2; hinted=1; }

    echo >&2
    echo "What this usually means:" >&2
    if says "no accounts|no account for team|not signed in|there are no accounts registered|session has expired|unable to log in|requires a development team"; then
        if [[ $AUTH_MODE == xcode ]]; then
            hint "Xcode has no usable Apple ID for team $TEAM. Add one in Xcode → Settings → Accounts, or set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH to use an API key."
        else
            hint "App Store Connect didn't accept the API key for team $TEAM. Check the key belongs to that team and hasn't been revoked."
        fi
    fi
    if says "authentication credentials are missing or invalid|invalid (api )?key|NOT_AUTHORIZED|(status|http)[^0-9]{0,12}401|401 unauthorized"; then
        hint "The API key was refused: check ASC_KEY_ID matches the .p8 file, ASC_ISSUER_ID is the team's issuer id (App Store Connect → Users and Access → Integrations), and the key is still active."
    fi
    if says "cloud signing permission|permission to (create|access).*certificate|FORBIDDEN|does not have permission"; then
        hint "The account or key can't use cloud-managed distribution signing. It needs the Admin role (App Manager isn't enough)."
    fi
    if says "failed registering bundle identifier|cannot be registered to your development team|identifier .* is not available|no app id|doesn't match any app id|no profiles for '$BUNDLE_ID'"; then
        hint "The bundle id $BUNDLE_ID isn't registered to team $TEAM (or another team holds it). An Admin key or Xcode account registers it on the next run; otherwise add it in Certificates, Identifiers & Profiles → Identifiers with iCloud (container $CONTAINER) and Push Notifications."
    fi
    if says "no suitable application records|cannot determine the apple id from bundle id|no app (record )?(was )?found|app record|could not find (the )?app"; then
        hint "App Store Connect has no app record for $BUNDLE_ID on this platform. Create it: App Store Connect → Apps → + → New App, bundle id $BUNDLE_ID, platforms iOS and macOS; add tvOS on the app's page with + Platform. The API can't create apps or platforms."
    fi
    if says "choose a certificate to revoke|maximum number of .*certificates|reached the maximum"; then
        hint "The team is at its certificate limit. Revoke an unused Apple Development certificate in Certificates, Identifiers & Profiles → Certificates, then run again."
    fi
    if says "your team has no devices"; then
        hint "The iOS and Apple TV archives are development-signed first, and a development profile needs at least one registered device of that kind. Register an iPhone or iPad, or an Apple TV for the tv archive (Xcode → Window → Devices and Simulators, or the developer site)."
    fi
    if says "redundant binary upload|bundle version must be higher|must contain a higher version|has already been (used|uploaded)"; then
        hint "App Store Connect already has build $BUILD_NUMBER, or a higher one, for this version. Run again with a higher BUILD_NUMBER, or raise MARKETING_VERSION in project.yml."
    fi
    if says "icloud|aps-environment|push notification" && says "provisioning profile"; then
        hint "The App ID is missing a capability the entitlements ask for. In Certificates, Identifiers & Profiles → Identifiers → $BUNDLE_ID, turn on iCloud (CloudKit, container $CONTAINER) and Push Notifications."
    fi
    (( hinted )) || echo "  (nothing recognised; the errors above are xcodebuild's own)" >&2
}

# Runs xcodebuild with all of its output in the log named by $1. On failure,
# prints xcodebuild's errors, what they usually mean, and the log's path, then
# stops the script.
xcb() {
    local log=$1
    shift
    if xcodebuild "$@" > "$log" 2>&1; then
        return 0
    fi
    echo >&2
    grep -E "(^|[[:space:]])error:|^Error|\*\* [A-Z ]+ FAILED \*\*" "$log" | awk '!seen[$0]++' | tail -30 >&2 \
        || tail -40 "$log" >&2
    explain_failure "$log"
    echo >&2
    die "xcodebuild failed. Full log: ${log#"$ROOT"/}"
}

# Writes the export options: App Store Connect distribution, cloud-managed
# signing, symbols included, and either straight to TestFlight or into a
# folder. manageAppVersionAndBuildNumber stays at its default (YES), the same
# as the workflow's.
write_export_options() {
    local plist=$1 destination=$2
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>$TEAM</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>destination</key>
    <string>$destination</string>
</dict>
</plist>
PLIST
}

# Stops before an upload if the archive didn't take the build number (a
# project.yml override, say), since App Store Connect would then reject it as
# a duplicate after a long wait.
check_archive_build_number() {
    local archive=$1 found
    found=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$archive/Info.plist" 2>/dev/null || echo "?")
    [[ $found == "$BUILD_NUMBER" ]] || die "the archive's build number is $found, not $BUILD_NUMBER"
}

# Exports the archive in $1 for App Store Connect into $2: uploads it unless
# --no-upload was given.
export_archive() {
    local archive=$1 export_path=$2 label=$3 destination=upload
    [[ $UPLOAD == YES ]] || destination=export
    local plist="$OUT/ExportOptions-$label.plist"
    write_export_options "$plist" "$destination"
    if [[ $UPLOAD == YES ]]; then
        echo "Uploading the $label build to App Store Connect…"
    else
        echo "Exporting the $label build (no upload)…"
    fi
    xcb "$OUT/$label-export.log" -exportArchive \
        -archivePath "$archive" \
        -exportOptionsPlist "$plist" \
        -exportPath "$export_path" \
        -allowProvisioningUpdates \
        ${AUTH[@]+"${AUTH[@]}"}
}

# MARK: - iOS

release_ios() {
    local archive="$OUT/Hearth-iOS.xcarchive"
    echo "Archiving the iOS app (Release, build $BUILD_NUMBER)…"
    # Signed by Xcode's automatic signing with a development identity, which
    # -allowProvisioningUpdates creates or fetches as needed; the export
    # re-signs it for distribution.
    xcb "$OUT/ios-archive.log" archive \
        -project Hearth.xcodeproj \
        -scheme Hearth \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$archive" \
        -derivedDataPath "$DERIVED_DATA" \
        -allowProvisioningUpdates \
        ${AUTH[@]+"${AUTH[@]}"} \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    check_archive_build_number "$archive"
    export_archive "$archive" "$OUT/ios-export" ios
    if [[ $UPLOAD == YES ]]; then
        echo "Uploaded iOS build $BUILD_NUMBER. It appears in TestFlight once App Store Connect finishes processing it."
    else
        echo "Exported to ${OUT#"$ROOT"/}/ios-export (nothing uploaded)."
    fi
}

# MARK: - Mac

release_mac() {
    local archive="$OUT/Hearth-macOS.xcarchive"
    echo "Archiving the Mac app (Release, build $BUILD_NUMBER, unsigned)…"
    # Built unsigned and signed ad hoc below, as the workflow's mac job does
    # and for the same reason: a Mac development profile only covers
    # registered Macs, and manual signing without a profile is refused because
    # CloudKit and push need one. The export re-signs it for the App Store.
    xcb "$OUT/mac-archive.log" archive \
        -project Hearth.xcodeproj \
        -scheme Hearth-macOS \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath "$archive" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    check_archive_build_number "$archive"

    # Left unsigned, the archive would carry no entitlements and the export
    # would ship the app without its sandbox or CloudKit. The helper resolves
    # the entitlements' $(…) variables and signs VLCKit's framework first.
    local app="$archive/Products/Applications/Hearth.app"
    [[ -d $app ]] || die "no app at ${app#"$ROOT"/}"
    local bundle_id
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
    [[ $bundle_id == "$BUNDLE_ID" ]] || die "the Release archive's bundle id is $bundle_id, not $BUNDLE_ID"
    TEAM=$TEAM "$ROOT/scripts/codesign-app.sh" --hardened-runtime "$app" App/Resources/App-macOS.entitlements \
        2>> "$OUT/mac-sign.log" \
        || die "ad hoc signing failed; see ${OUT#"$ROOT"/}/mac-sign.log"

    export_archive "$archive" "$OUT/mac-export" mac
    if [[ $UPLOAD == YES ]]; then
        echo "Uploaded Mac build $BUILD_NUMBER. It appears in TestFlight once App Store Connect finishes processing it."
    else
        echo "Exported to ${OUT#"$ROOT"/}/mac-export (nothing uploaded)."
    fi
}

# MARK: - Apple TV

release_tv() {
    local archive="$OUT/Hearth-tvOS.xcarchive"
    echo "Archiving the Apple TV app (Release, build $BUILD_NUMBER)…"
    # Signed the way the iOS archive is, and re-signed by the export the same
    # way; the same bundle id, so it joins the iOS and Mac app's TestFlight.
    xcb "$OUT/tv-archive.log" archive \
        -project Hearth.xcodeproj \
        -scheme Hearth-tvOS \
        -configuration Release \
        -destination 'generic/platform=tvOS' \
        -archivePath "$archive" \
        -derivedDataPath "$DERIVED_DATA" \
        -allowProvisioningUpdates \
        ${AUTH[@]+"${AUTH[@]}"} \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    check_archive_build_number "$archive"
    export_archive "$archive" "$OUT/tv-export" tv
    if [[ $UPLOAD == YES ]]; then
        echo "Uploaded Apple TV build $BUILD_NUMBER. It appears in TestFlight once App Store Connect finishes processing it."
    else
        echo "Exported to ${OUT#"$ROOT"/}/tv-export (nothing uploaded)."
    fi
}

# MARK: - Run

commit=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "Hearth $PLATFORM, build $BUILD_NUMBER, commit $commit, Xcode $xcode_version"
echo "Signing as $IDENTITY"
if [[ -n $(git -C "$ROOT" status --porcelain 2>/dev/null) ]]; then
    echo "warning: the working tree has uncommitted changes, and this build includes them."
fi
echo "Reminder: a build that changes the household model needs scripts/cloudkit/init-schema.sh and a Production deploy first."
echo

echo "Generating Hearth.xcodeproj…"
xcodegen generate --quiet

case "$PLATFORM" in
    ios) release_ios ;;
    mac) release_mac ;;
    tv) release_tv ;;
    all) release_ios; echo; release_mac; echo; release_tv ;;
esac
