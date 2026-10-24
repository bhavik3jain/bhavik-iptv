# CLAUDE.md

Hearth (working title) — an IPTV player for Stalker portals, Xtream logins and M3U playlists, with Netflix-style profiles shared by a household through iCloud. SwiftUI, iOS 18 / macOS 15, built with Xcode 27.1 (iOS 27.1 SDK, needed for iPhone Duo), Swift 6. TestFlight only for now.

**Read `docs/TRACKING.md` first** — status, blockers, workstreams and the session log. Update it at the end of a session. The specs are in `docs/handoff/` (requirement ids like SRC-1 come from `docs/handoff/docs/2-Product-spec.md`). This file is only the things that cost an hour if you don't know them; many are lessons from the sister app Multitrack (`../bhavik-ios`, its `.claude/CLAUDE.md`).

## Layout and the rules that hold it together

- `project.yml` is the source of truth; `Hearth.xcodeproj` is XcodeGen output and gitignored. Run `xcodegen generate` after any change to `project.yml` or a file move. Signing, entitlements and Info.plist keys live in `project.yml`, never Xcode's GUI. XcodeGen has no `resources:` key — assets go under `sources:` (a `resources:` key is silently ignored).
- `App/Resources/Info*.plist` are generated from `project.yml`'s `info:` blocks; hand edits vanish.
- Packages: `Core` (depends on nothing) · `SourceKit` (nothing) · `CatalogKit` (Core, SourceKit) · `HouseholdKit` (Core) · `PlayerKit` (Core, VLCKit) · features (`HomeFeature`, `LiveTVFeature`, `LibraryFeature`, `ProfilesFeature`, `HouseholdFeature`, `SearchFeature`, `SettingsFeature`: Core plus the kits they need, **never each other**). SourceKit and CatalogKit never touch iCloud; HouseholdKit never talks to a provider; VLCKit is the only remote dependency and only PlayerKit imports it.
- **Public APIs marked CONTRACT are additive-only.** Features and the app compile against them.
- Features reach other screens through Core's `HearthRoute` (`NavigationLink(value:)`, mapped in `App/Sources`) and start playback with `@Environment(\.play)` + `PlayIntent`. The app's playback coordinator resolves a fresh link, checks stream limits, opens `PlayerView`, writes progress and who's-watching rows.
- Services reach views as environment objects: `CatalogService`, `HouseholdStore`, `ProfileSession`.

## Platforms: one place for conditionals

- Feature packages contain **zero** `#if os(...)`. iOS-only modifiers go through shims in `Core/MacCompat.swift` (`inlineNavigationTitle()`, `urlEntryKeyboard()`, `hearthFullScreenCover`, …). Add a shim there rather than a conditional at a call site.
- Features ask `@Environment(\.hearthLayout)` (`.compact` or `.sidebar`) — never the platform, the idiom, the orientation or `UIScreen.main`. `.sidebar` is the Mac, iPad and **iPhone Duo's inner display** (regular width). The app sets it once with `.hearthLayoutFromSizeClass()`.
- `App/Sources` is the composition root and may use `#if os(macOS)` directly.
- `if #available(iOS 26, *)` does not gate macOS: write `#available(iOS 26, macOS 26, *)`.

## iPhone Duo

Folded it is a compact iPhone; opened, the inner display is regular × regular, like a small iPad. Rules: lay out by size class; `NavigationSplitView` and `TabView(.sidebarAdaptable)` adapt on their own; keep controls inside the safe area and let video and artwork run past it (`.ignoresSafeArea()` on backgrounds only); never assume opposite insets are equal; never `UIScreen.main` (use the scene or trait collection). The simulator is "iPhone Duo" on the iOS 27.1 runtime; Device Hub has the open/close/rotate controls (no `simctl` hinge command).

## Household store (Core Data + CloudKit) — model rules or a crash at launch

Every non-optional attribute has a default; every relationship is optional with an inverse; nothing is unique; enums are `…Raw` strings with a fallback. Predicates and sort descriptors touch stored attributes only. Never call the sharing API on the main thread; members leave a share (purge the zone), never delete its root. Don't write what changes every second: progress on pause/stop/finish/background and every 5 minutes; who's-watching rows at play, stop and every 10 minutes. Adding an entity or attribute needs the schema ritual before a TestFlight build: run a Debug build with `-InitializeCloudKitSchema YES`, check Development in the CloudKit Console, Deploy Schema Changes to Production. Encrypted attributes (logins) must be marked before the first Production deploy.

## Privacy

No analytics, ads or tracking. Logins, MACs and device ids are never logged, printed or committed — use `SourceConfiguration.redacted` and `Redaction`. Test fixtures are scrubbed provider responses.

## Building and testing

- **Never point `-derivedDataPath` or `--scratch-path` at `/tmp`.** Use the default DerivedData or your session's scratchpad, and delete one-off build folders.
- Package tests: `cd Packages/<Name> && swift test` (runs on macOS). iOS-only compile errors only show in an iOS build: `xcodebuild build -scheme <Package> -destination 'generic/platform=iOS Simulator'` from the package directory, or the app scheme.
- App: `xcodegen generate`, then `xcodebuild -project Hearth.xcodeproj -scheme Hearth -destination 'platform=iOS Simulator,name=iPhone Duo'` (or `Hearth-macOS`). Unsigned local builds: `CODE_SIGNING_ALLOWED=NO`.
- Swift Testing only (no XCTest). Views are untested by policy: put logic in value types and test those. Network is faked with a `URLProtocol` stub. Tests needing a real login are gated with `.enabled(if:)` and skip by name.
- Debug launch arguments (`#if DEBUG`): `-StubProvider YES` (a fake provider with Apple's public HLS samples, no login), `-InMemoryStores YES` (no iCloud), `-SourceProbe <name>` (sign in to a real source, print each step with timings, logins masked), `-InitializeCloudKitSchema YES`.
- Debug is its own app (`com.bhavikjain.hearth.dev`, "Hearth Dev") with its own container. Never give Debug the release bundle id.
