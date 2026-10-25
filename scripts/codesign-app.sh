#!/bin/bash
# Signs a built Mac app by hand: every piece of nested code first, deepest
# first, then the app with its entitlements. Used wherever the Mac app is built
# with CODE_SIGNING_ALLOWED=NO and signed afterwards: the TestFlight
# workflow's mac job, scripts/testflight.sh mac, scripts/run-mac-local.sh and
# scripts/cloudkit/init-schema.sh.
#
#   scripts/codesign-app.sh [--identity "<identity>"] [--hardened-runtime] <App.app> <entitlements>
#
# --identity defaults to "-" (ad hoc). --hardened-runtime adds
# `--options runtime`; leave it off for a build run on this Mac, since library
# validation refuses ad hoc frameworks, which carry no team id.
#
# The entitlements file may hold the variables Xcode fills in when it signs:
# $(TeamIdentifierPrefix), $(CFBundleIdentifier) and $(PRODUCT_BUNDLE_IDENTIFIER).
# They are resolved from TEAM (default Y4M3S6H4NK) and the app's own
# CFBundleIdentifier. Any other $(…) stops the script: signed with a literal
# "$(…)", the app would silently lose that entitlement.
#
# Why inside out: codesign refuses a bundle whose nested code is unsigned, and
# VLCKit is a dynamic framework that may carry dylibs of its own. Signing the
# framework before the dylibs inside it fails the same way, so paths are
# signed in order of depth, deepest first.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
usage() {
    echo "usage: scripts/codesign-app.sh [--identity \"<identity>\"] [--hardened-runtime] <App.app> <entitlements>" >&2
    exit 2
}

identity=-
options=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) [[ $# -ge 2 ]] || usage; identity=$2; shift 2 ;;
        --hardened-runtime) options=(--options runtime); shift ;;
        -h|--help) usage ;;
        -*) echo "error: unknown option '$1'" >&2; usage ;;
        *) break ;;
    esac
done
[[ $# -eq 2 ]] || usage
app=${1%/}
entitlements_in=$2
team=${TEAM:-Y4M3S6H4NK}

[[ -d $app/Contents ]] || die "$app is not a Mac app bundle"
[[ -f $entitlements_in ]] || die "no entitlements file at $entitlements_in"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null) \
    || die "can't read CFBundleIdentifier from $app/Contents/Info.plist"

entitlements=$(mktemp -t hearth-entitlements)
trap 'rm -f "$entitlements"' EXIT
sed -e "s/\$(TeamIdentifierPrefix)/$team./g" \
    -e "s/\$(CFBundleIdentifier)/$bundle_id/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$bundle_id/g" \
    "$entitlements_in" > "$entitlements"
if grep -q '\$(' "$entitlements"; then
    die "$(basename "$entitlements_in") has a \$(…) variable this script doesn't fill in: $(grep -o '\$([A-Za-z_]*)' "$entitlements" | sort -u | tr '\n' ' ')"
fi

# Bundles that hold code (frameworks, XPC services, extensions, helper apps)
# and loose dylibs; symlinks are skipped, so a framework's Versions/Current
# is not signed twice. Resource bundles (SwiftPM's *.bundle) hold no code and
# are sealed by the app's own signature.
nested=$(find "$app/Contents" -mindepth 1 \
    \( -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) \) \
    -o \( -type f -name '*.dylib' \) \
    | awk -F/ '{ print NF "\t" $0 }' | sort -rn -k1,1 | cut -f2-)

if [[ -n $nested ]]; then
    while IFS= read -r path; do
        codesign --force --sign "$identity" ${options[@]+"${options[@]}"} --timestamp=none "$path" \
            || die "signing ${path#"$app"/} failed"
    done <<< "$nested"
fi

codesign --force --sign "$identity" ${options[@]+"${options[@]}"} --timestamp=none \
    --entitlements "$entitlements" "$app" || die "signing $(basename "$app") failed"
codesign --verify --strict "$app" || die "the signature on $(basename "$app") doesn't verify"
echo "Signed $(basename "$app") ($bundle_id) as $([[ $identity == - ]] && echo "ad hoc" || echo "$identity")$([[ ${#options[@]} -gt 0 ]] && echo ", hardened runtime" || true)" >&2
