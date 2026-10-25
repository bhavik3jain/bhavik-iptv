# Hearth

Hearth (a working title) is an IPTV player for iPhone, iPad and Mac. It plays Stalker portals (MAC address), Xtream Codes logins and M3U playlists with XMLTV guides, and adds Netflix-style profiles that a whole household shares through iCloud, with favorites, progress and who's watching synced between members. SwiftUI, iOS 18 / macOS 15, Swift 6, installed through TestFlight only for now. The specs live in [docs/handoff](docs/handoff/README.md): requirement ids such as SRC-1 come from the [product spec](docs/handoff/docs/2-Product-spec.md). Status, blockers and the session log are in [docs/TRACKING.md](docs/TRACKING.md).

## Layout

```
App/
  Sources/        Composition root: navigation, the playback coordinator, launch arguments (the only place #if os() is allowed)
  Resources/      Entitlements, the asset catalog, Info*.plist (generated from project.yml; hand edits vanish)
Packages/
  Core/           Theme, shared components, HearthRoute, PlayIntent, the Mac shims (MacCompat.swift)
  SourceKit/      Stalker and Xtream clients, the M3U and XMLTV parsers, one SourceClient protocol
  CatalogKit/     The per-device catalog store, imports from SourceKit, stable keys, search
  HouseholdKit/   The household store (Core Data + CloudKit), sharing, roles, profiles, who's watching
  PlayerKit/      The engine protocol, the AVPlayer and VLCKit engines, picture in picture, the player screen
  HomeFeature/ LiveTVFeature/ LibraryFeature/ ProfilesFeature/ HouseholdFeature/ SearchFeature/ SettingsFeature/
scripts/          Run, release and CloudKit schema scripts (below)
.github/          tests.yml on push and pull request, testflight.yml for releases
project.yml       XcodeGen's input: targets, schemes, signing, entitlements, Info.plist keys
docs/             TRACKING.md and the handoff specs and mockups
```

The rules that hold it together:

- **Dependencies:** Core and SourceKit depend on nothing; CatalogKit on Core and SourceKit; HouseholdKit and PlayerKit on Core. Features depend on Core plus the kits they need, **never on each other**: they reach other screens through `HearthRoute` and start playback with `@Environment(\.play)`.
- **Boundaries:** SourceKit and CatalogKit never touch iCloud; HouseholdKit never talks to a provider. VLCKit is the only remote dependency, and only PlayerKit imports it.
- **Contracts:** public APIs marked CONTRACT are additive-only; features and the app compile against them.
- **Platforms:** feature packages contain no `#if os(...)`. They read `@Environment(\.hearthLayout)` (`.compact` or `.sidebar`) and use Core's shims for iOS-only modifiers.

## Requirements

- **Xcode 27.1** (27A9275). The iOS 27.1 SDK is what gives the app full-screen layout on iPhone Duo's inner display; the iPhone Duo simulator needs the iOS 27.1 runtime (`xcodebuild -downloadPlatform iOS`, or Xcode → Settings → Components).
- **XcodeGen:** `brew install xcodegen`. `Hearth.xcodeproj` is generated and gitignored. Run `xcodegen generate` after cloning, after any change to `project.yml`, and after adding or moving files.
- Optional: `brew install xcbeautify` for readable `xcodebuild` output (CI uses it).

## Build, run and test

```bash
xcodegen generate

# The app on a simulator, stub provider, in-memory stores, no login or iCloud
scripts/run-sim.sh "iPhone Duo"
scripts/run-sim.sh "iPhone 18 Pro" -AppleLanguages "(fr)"     # extra arguments go to the app
CONSOLE=YES scripts/run-sim.sh "iPhone Duo"                    # stay attached to the app's output

# The Mac app, unsigned build signed ad hoc, no Apple ID needed
scripts/run-mac-local.sh

# One package's tests (on macOS)
cd Packages/SourceKit && swift test

# One package for the iOS Simulator (iOS-only compile errors show only here)
cd Packages/PlayerKit && xcodebuild build -scheme PlayerKit -destination 'generic/platform=iOS Simulator'

# Every package's tests, the way CI runs them
xcodebuild test -project Hearth.xcodeproj -scheme AllPackageTests \
  -destination "platform=iOS Simulator,name=iPhone Duo,arch=$(uname -m)"

# The apps, unsigned
xcodebuild build -project Hearth.xcodeproj -scheme Hearth \
  -destination 'platform=iOS Simulator,name=iPhone Duo' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Hearth.xcodeproj -scheme Hearth-macOS \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

The scripts keep DerivedData in `build/DerivedData` and their logs in `build/logs` (both gitignored). Never point `-derivedDataPath` at `/tmp`.

`scripts/run-mac-local.sh` signs with `App/Resources/App-macOS-Local.entitlements`: the sandbox and outgoing connections, but no iCloud, since an app that claims iCloud without a provisioning profile is killed at launch. So it always runs with `-InMemoryStores YES`. iCloud on the Mac needs a profile-signed build from Xcode, signed in.

Debug builds are their own app, **Hearth Dev** (`com.bhavikjain.hearth.dev`), with their own sandbox and store, and they sync with iCloud's Development environment only. Never give Debug the release bundle id.

**iPhone Duo.** Folded, it is a compact iPhone. Opened, the inner display is regular × regular, like a small iPad, and the app switches to its `.sidebar` layout. Open, close and rotate it from **Device Hub**'s controls; `simctl` has no hinge command. Check both states and both orientations: controls stay inside the safe area, video and artwork run past it, and opposite insets are not always equal.

**Tests.** Swift Testing only. Logic lives in value types and is tested; views are not. The network is faked with a `URLProtocol` stub, fixtures are scrubbed provider responses, and nothing touches iCloud. A test that needs a real login is gated with `.enabled(if:)` and skips by name without one. Every package's suite must be listed in `project.yml`'s `AllPackageTests` scheme, or CI never runs it.

## Debug launch arguments

Debug builds only (`#if DEBUG`). Pass them in Xcode (Product → Scheme → Edit Scheme → Run → Arguments) or after the simulator name in `scripts/run-sim.sh`.

| Argument | What it does |
| --- | --- |
| `-StubProvider YES` | A fake provider behind `URLProtocol` with Apple's public HLS samples: channels, a guide and movies with no login |
| `-InMemoryStores YES` | Both stores in memory, no iCloud |
| `-SourceProbe <name>` | Signs in to that real source, lists categories, fetches one link, and prints each step with timings, logins masked |
| `-InitializeCloudKitSchema YES` | Sends the household model's schema to CloudKit Development (run by `scripts/cloudkit/init-schema.sh`) |

## CI

`.github/workflows/tests.yml` runs on pushes to `main` and `build/**`, on every pull request (docs-only changes skip it) and by hand. On the `xcode-27` runner with Xcode 27.1, it:

- generates the project;
- picks a simulator (iPhone Duo if the image has it, else an iPhone on the newest runtime);
- runs `AllPackageTests`, which also builds the iOS app;
- builds `Hearth-macOS` unsigned, in a parallel job.

SwiftPM checkouts (VLCKit is large) are cached under `build/SourcePackages`. CI holds no provider credentials and no Apple account.

## Release

Builds go to internal TestFlight, which skips App Review. Both platforms are one App Store Connect app (Universal Purchase: one bundle id, `com.bhavikjain.hearth`), so one TestFlight serves iPhone, iPad and Mac. Signing is cloud-managed: Apple holds the distribution key.

**What the owner sets up once:**

1. **The app record.** In App Store Connect → Apps → + → New App, create the app for bundle id `com.bhavikjain.hearth` with platforms iOS and macOS. The API can't create apps.
2. **The App ID.** In Certificates, Identifiers & Profiles → Identifiers, `com.bhavikjain.hearth` needs iCloud (CloudKit, container `iCloud.com.bhavikjain.hearth`) and Push Notifications. A signed build with automatic signing usually turns these on.
3. **One way to sign the upload:**
   - **For the workflow:** a GitHub deployment environment named `testflight`, holding the secrets below. An environment rather than repository secrets, so only the branches and tags it allows can read them.
   - **For `scripts/testflight.sh`:** either the same API key in your shell, or the team's Apple ID signed in to Xcode (Settings → Accounts).

| Secret | What it is |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect API key id (Users and Access → Integrations) |
| `ASC_ISSUER_ID` | The team's issuer id, on the same page |
| `ASC_PRIVATE_KEY` | `base64 -i AuthKey_XXXX.p8`. The key needs the **Admin** role: with App Manager, cloud signing fails with "Cloud signing permission error" |
| `IOS_DEV_P12` | `base64 -i development.p12`: an Apple Development certificate exported from Keychain Access. The iOS archive reuses it instead of minting a new certificate every run until the team hits its limit |
| `IOS_DEV_P12_PASSWORD` | That `.p12`'s password |

**Shipping a build:**

```bash
gh workflow run TestFlight --ref main      # or: git tag v0.1.1 && git push --tags
scripts/testflight.sh ios                  # local: ios, mac or all; --no-upload archives and exports only
```

- **The workflow:** builds both platforms in parallel jobs. Build numbers are the run number + 100; the `build_number` input overrides it. A tag doesn't run Tests, so tag a commit whose tests passed.
- **`scripts/testflight.sh`:** uses the API key when `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH` (the `.p8` file) are all set, otherwise the Apple ID in Xcode. Build numbers default to UTC `yyDDDHHMM` (day of the year, so it stays under 2^31); `BUILD_NUMBER` overrides it. Archives, exports and logs land in `build/testflight/<build>/`. When an upload fails, it explains the usual causes: no account, no app record, an unregistered bundle id, the wrong key role, or a duplicate build number.
- **The Mac build, both ways:** archived unsigned, then signed ad hoc with `App-macOS.entitlements` (`scripts/codesign-app.sh`), because a Mac development profile only covers registered Macs. The App Store export re-signs it.

**The CloudKit schema ritual.** Do this before any build that adds a household entity or attribute. Production never creates record types on its own, so a build shipped without it saves locally and never syncs.

1. `scripts/cloudkit/init-schema.sh` sends the schema to Development. It signs a Debug Mac build with this Mac's Apple Development certificate and a Mac profile. `--simulator ["<name>"]` uses a simulator signed in to an Apple Account instead.
2. In the [CloudKit Console](https://icloud.developer.apple.com), `iCloud.com.bhavikjain.hearth` → Development: check the record types and fields (`CD_<Entity>`), and that logins are encrypted fields.
3. Deploy Schema Changes to Production, then ship the build.

Encrypted attributes must be marked before the first Production deploy, since that can't be changed later.

## Privacy

- No analytics, ads or tracking libraries (PRIV-1).
- Logins, MACs and device ids are never logged, printed or committed (PRIV-2). Use `SourceConfiguration.redacted` and `Redaction`; `-SourceProbe` masks them, and test fixtures are scrubbed provider responses.
- Logins are stored as encrypted CloudKit fields, so they open on every member's devices and nowhere else (PRIV-3).
- The scripts and workflows never print the API key, the certificate or their passwords. The key and the signing keychain are deleted at the end of every run, failed or not.
