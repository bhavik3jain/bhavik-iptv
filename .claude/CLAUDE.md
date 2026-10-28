# CLAUDE.md

Hearth (working title) — an IPTV player for Stalker portals, Xtream logins and M3U playlists, with Netflix-style profiles shared by a household through iCloud. iPhone (including iPhone Duo), iPad, Mac and Apple TV. SwiftUI, Swift 6, iOS 18 / macOS 15 deployment, built with **Xcode 27.1** (the iOS 27.1 SDK is the first with iPhone Duo's full-screen layout). Distributed through TestFlight only. Repo `bhavik3jain/bhavik-iptv` (public); sister app Multitrack is `bhavik3jain/bhavik-ios` (`../bhavik-ios`), whose CloudKit, sharing and CI code this repo borrows.

**Read first:** `docs/TRACKING.md` (status, blockers, workstreams, the dated session log — add to it at the end of a session), `docs/RELEASE.md` (TestFlight, secrets, the iCloud schema ritual), `README.md` (commands). Specs and mockups: `docs/handoff/` (requirement ids like SRC-1 and PRF-3 come from `docs/handoff/docs/2-Product-spec.md`). This file is only the things that cost an hour if you don't know them.

## The project file is generated

- `project.yml` is the source of truth; `Hearth.xcodeproj` is XcodeGen output and gitignored. Run `xcodegen generate` after any change to `project.yml` or a file move. Signing, entitlements and Info.plist keys live in `project.yml`, never Xcode's Signing & Capabilities tab.
- `App/Resources/Info*.plist` are generated from the targets' `info:` blocks — hand edits vanish. `CFBundleShortVersionString` and `CFBundleVersion` are set there to `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`: XcodeGen's defaults are the literals `1.0` / `1`, which silently ignored every build number passed to an archive.
- XcodeGen has no `resources:` key — assets go under `sources:`; a `resources:` key is silently ignored.
- Debug is its own app: `com.bhavikjain.hearth.dev` ("Hearth Dev"), own sandbox and keychain, syncing with iCloud **Development** only. Never give Debug the release id (it crashed Multitrack's TestFlight three times).

## Packages and the rules that hold them together

- `Core` (nothing) · `SourceKit` (nothing) · `CatalogKit` (Core, SourceKit) · `HouseholdKit` (Core) · `PlayerKit` (Core, VLCKit) · `DownloadKit` (nothing) · features `HomeFeature`, `LiveTVFeature`, `LibraryFeature`, `ProfilesFeature`, `HouseholdFeature`, `SearchFeature`, `SettingsFeature` (Core plus the kits they need, **never each other**). SourceKit and CatalogKit never touch iCloud; HouseholdKit and DownloadKit never talk to a provider (the app hands DownloadKit a fresh link); VLCKit (4.0.0-a25 from code.videolan.org, ≈900 MB first download, pinned exactly) is the only remote dependency and only PlayerKit imports it, behind `#if canImport(VLCKit)`.
- Public APIs marked **CONTRACT** are additive-only: change what they do, never their signatures.
- Navigation between features: Core's `HearthRoute` with `NavigationLink(value:)` / `@Environment(\.openRoute)`, mapped to views by `RouteDestination` in `App/Sources/AppNavigation.swift`. Playback: `@Environment(\.play)` with a `PlayIntent`; `App/Sources/PlaybackCoordinator.swift` resolves a fresh link, checks stream limits, opens `PlayerView`, writes progress and who's-watching rows.
- Services reach views as environment objects: `CatalogService`, `HouseholdStore`, `ProfileSession`.
- Name clashes bite across packages: Core's `StreamBarUsage` is not HouseholdKit's `StreamUsage`, and HouseholdKit's `ProgressKind` clashes with Foundation's — spell it `HouseholdProgressKind` in any file that imports Foundation.

## Platforms: one place for conditionals

- Feature packages contain **zero** `#if os(...)`. An iOS-only (or Mac-only) modifier a feature needs becomes a shim in `Packages/Core/Sources/Core/MacCompat.swift` (`inlineNavigationTitle()`, `urlEntryKeyboard()`, `hearthFullScreenCover`, …) or `CloudSharingPresenter.swift`.
- Features ask `@Environment(\.hearthLayout)` — `.compact` or `.sidebar` — never the platform, the idiom, the orientation or `UIScreen.main`. `.sidebar` is the Mac, iPad and iPhone Duo's inner display; the app sets it once with `.hearthLayoutFromSizeClass()`.
- `App/Sources` is the composition root and may use `#if os(...)` directly. Kits may too (PlayerKit's engine views, HouseholdKit's one nudge).
- `if #available(iOS 26, *)` doesn't gate macOS: write `#available(iOS 26, macOS 26, *)`.
- iPhone tab bar: five tabs. Sidebar-only tabs (Search, Household, Settings) are added only at regular width — `.tabPlacement(.sidebarOnly)` alone still folds them into a "More" tab on the phone and hides My List.

## iPhone Duo

Folded it's a compact iPhone; opened it's regular × regular (≈466×678 pt, status bar down one side). Lay out by size class, keep controls in the safe area and let video and artwork run past it, never assume symmetric insets, never `UIScreen.main`. The simulator is "iPhone Duo" on the iOS 27.1 runtime; open/close/rotate it in Device Hub (Xcode 27's Simulator; no `simctl` hinge command). The Claude desktop app's simulator side panel doesn't show the Duo — drive it headlessly. Don't run CI tests on it (first boot can take minutes); `scripts/pick-simulator.sh` skips it unless asked by name.

## Stalker portals: what real providers do

Learned against the owner's real portal (iSTB worked, Hearth didn't):
- The address a provider gives can be a host that only **301-redirects its root** to the real portal and answers every API path with 404. Discovery tries the typed host's paths, then follows where the typed page and the root land (`StalkerClient.discoverAndHandshake`).
- **Device ids**: send `device_id`, `device_id2` and `signature` **blank** unless the provider gave them. Some portals refuse stalkerhek's 64-`f` placeholder ("Device conflict - device_id mismatch"); it's tried once only after blank ids are refused.
- Catalogs can be enormous (162,634 VOD titles at 14 per page, ~1.5 s a page). CatalogKit imports a movie/show list whole only under `CatalogImporter.fullImportLimit` (5,000); otherwise each category's first page, four at a time, with a `BrowseCursor` per category (persisted in `SourceState.browseJSON`), and `CatalogService.loadMore(kind:categoryID:)` as a category is browsed. Never reintroduce a whole-catalog import for Stalker.
- Big portals file series categories under `vod` too; a movie category whose first page holds no movies is dropped.
- Pages go out as `p = page + 1` (Ministra reads `p=0` as "last watched"). Links expire: fetch one at every play, never store it.
- Debug a portal with a throwaway executable that depends on `Packages/SourceKit` (or CatalogKit) and reads the login from environment variables, or `-SourceProbe <source name>`. Logins and MACs never go into the repo, logs or docs.

## Household store (Core Data + CloudKit) — model rules or a crash at launch

- Every non-optional attribute has a default; every relationship is optional with an inverse; nothing is unique; enums are `…Raw` strings with a fallback. Predicates and sort descriptors touch stored attributes only. Logins are encrypted attributes (`allowsCloudEncryption`), which must be in place before the first Production deploy.
- Core Data's classes set themselves up on first touch, and **two threads doing that at once deadlock**. `HouseholdStore.init` goes through `HouseholdModel.shared` before anything typed over `NSManagedObjectID`; keep any new Core Data first touch behind that one-time build (parallel tests hung forever until this was fixed).
- Never call the sharing API on the main thread; members leave a share (purge the zone), never delete its root.
- Don't write what changes every second: progress on pause/stop/finish/background and every 5 minutes; who's-watching rows at play, stop and every 10 minutes.
- Adding an entity or attribute needs the schema ritual (`docs/RELEASE.md` §3: `scripts/cloudkit/init-schema.sh`, then Deploy Schema Changes in the CloudKit Console) before the TestFlight build that ships it. A raw-string enum case is not a schema change.

## Downloads (DL-1, DL-2)

- `DownloadKit`'s `DownloadCenter` (an environment object) keeps the records in Application Support/Downloads/downloads.json and runs two background sessions: HLS through `AVAssetDownloadURLSession` (a `.movpkg` the system places; its path is kept relative to the home directory) and anything else as one file. No HLS downloads on tvOS: the TV offers none.
- Screens ask with `@Environment(\.download)`; the app's `PlaybackCoordinator` checks the stream limit (a running download takes a stream), resolves a fresh link and starts it, and keeps a who's-watching row per running download. `PlayerItemFactory` plays a finished download's file instead of asking the provider, and such a play takes no stream and writes no row.
- The simulator downloads HLS fine; its audio device can refuse to start (`-66681`), which stops AVPlayer on any stream there, downloaded or not.

## Signing and running

- **An unsigned build has no entitlements**, and the CloudKit-backed store then crashes at launch ("must have a com.apple.developer.icloud-services entitlement"). `CODE_SIGNING_ALLOWED=NO` builds are fine for compile checks and for runs with `-InMemoryStores YES`, nothing else. To run for real: `scripts/run-sim.sh <simulator>` (signs simulator builds the normal way) or Xcode; on the Mac, `xcodebuild … -scheme Hearth-macOS -configuration Debug -allowProvisioningUpdates` (development profile) — `scripts/run-mac-local.sh` is ad hoc, no iCloud, demo only.
- `scripts/run-sim.sh "iPhone 18 Pro"` runs the demo (`-StubProvider YES -InMemoryStores YES`); `REAL=YES scripts/run-sim.sh …` runs with the store on disk and no demo, for real sources.
- Only the iOS archive is development-signed (the team has an iPhone registered). The Mac and Apple TV archives are built `CODE_SIGNING_ALLOWED=NO` and signed ad hoc with their entitlements by `scripts/codesign-app.sh`: a development profile needs a registered device of that kind (tvOS failed with "Your team has no devices"), the App Store profile the export makes doesn't.
- Uploads: `scripts/testflight.sh ios|mac|tv|all` (Xcode's Apple ID, or `ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_PATH`), or the `TestFlight` workflow. Local build numbers are `yyDDDHHMM` (under 2^31). `xcodebuild -exportArchive` from a Claude-launched shell has reported "No Accounts" even with Xcode signed in; the owner runs uploads from their own Terminal or uses the API key.

## Building and testing

- **Never point `-derivedDataPath` or `--scratch-path` at `/tmp`.** Use the default DerivedData or your session's scratchpad, and delete one-off build folders.
- The repo lives under `~/Documents`, which iCloud Drive syncs: an in-tree `.build/…/*.xctest` gets Finder info and codesign fails. Run package tests with `swift test --scratch-path <outside ~/Documents>`; `swift build` in-tree is fine.
- iCloud Drive also makes **conflict copies** when branches switch quickly — `PINTests 2.swift`, `Hearth 2.xcodeproj` — untracked files that SwiftPM compiles anyway ("invalid redeclaration of …"). Find them with `find . -name "* [0-9].*" -not -path "./.git/*"`; delete a copy once `cmp` shows it identical to its original. (Moving the repo out of `~/Documents` would end both problems.)
- Swift Testing only (no XCTest). Views are untested by policy: logic lives in small value types, tested. Network is faked with a `URLProtocol` stub; nothing touches iCloud or a real provider (gate any such test with `.enabled(if:)` so it skips by name).
- The `AllPackageTests` scheme in `project.yml` runs every package's suite plus the app-hosted `HearthTests`; a suite left out of it never runs in CI. CI: `.github/workflows/tests.yml` (runner `xcode-27`, Xcode 27.1 pinned, docs-only changes skipped) and `testflight.yml` (by hand or a `v*` tag; secrets in the `testflight` environment, `docs/RELEASE.md` §2).
- Debug launch arguments (`#if DEBUG`, `App/Sources/LaunchOptions.swift`): `-InMemoryStores YES`, `-StubProvider YES` (demo provider with Apple's HLS samples and the mockup's household), `-SeedPIN 1234`, `-SelectProfile <name>`, `-OpenTab home|live|movies|shows|mylist`, `-OpenRoute series|movie|channel:first|<itemKey>`, `-AutoPlay first-channel|first-movie`, `-SourceProbe <source name>`, `-InitializeCloudKitSchema YES`.
- `sample` on this Mac's PATH is a broken Python script; use `/usr/bin/sample <pid>` to see where a hung process is stuck.

## Privacy

No analytics, ads or tracking. Logins, MACs, serials and device ids are never logged, printed or committed — use `SourceConfiguration.redacted`, `Redaction` and `Redaction.scrub`. Test fixtures are hand-written or scrubbed. The repo is public.
