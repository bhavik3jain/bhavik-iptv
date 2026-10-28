# Hearth — build tracker and handoff log

The single place to see what's built, what's in flight, what's blocked and what comes next. Anyone picking this up (a person or an agent) reads **Status**, **Blocked on the owner** and **Next up**, then the newest **Session log** entry. Update this file at the end of every working session; keep entries short and dated.

Specs live in [docs/handoff](handoff/README.md): the [handoff](handoff/docs/1-Handoff.md), the [product spec](handoff/docs/2-Product-spec.md) (requirement ids such as SRC-1 and PRF-2), the [technical spec](handoff/docs/3-Technical-spec.md) and the [source protocols](handoff/docs/4-Source-protocols.md). Mockups: [handoff/ui/png](handoff/ui/png).

## Status

| | |
| --- | --- |
| Goal | An IPTV player for Stalker portals with Netflix-style profiles, on iPhone (including iPhone Duo), iPad and Mac, installed through TestFlight |
| Version | 0.1 (build numbers come from CI run number + offset) |
| Branch | `main` on GitHub; work lands through pull requests with the Tests workflow (packages + iOS, Mac, Apple TV builds) |
| Toolchain | Xcode 27.1 (27A9275), Swift 6.4, iOS 27.1 SDK; deployment iOS 18 / macOS 15 |
| Bundle ids | `com.bhavikjain.hearth` (release), `com.bhavikjain.hearth.dev` (Debug) · iCloud `iCloud.com.bhavikjain.hearth` · team Y4M3S6H4NK |
| Builds | The whole app builds clean for iOS Simulator and macOS; runs on iPhone 18 Pro, iPhone Duo (iOS 27.1) and the Mac with the demo provider |
| Apple TV | `Hearth-tvOS` (tvOS 18, same bundle ids and iCloud container) builds and runs on the Apple TV 4K simulator (tvOS 27.0) with the demo provider: gate, Home, Live TV guide, Movies, Shows, My List, Search, Settings, details and the remote-driven player. Merged (PR #2); uploads to TestFlight from branch `testflight-tvos` on |
| TestFlight | Not yet uploaded — local `scripts/testflight.sh` with Xcode's Apple ID (owner signing in, creating the app record) |

## Blocked on the owner

These need you; nothing else waits on them until the upload step.

- [x] **App Store Connect app record** (created by the owner, 2026-10-27): bundle id `com.bhavikjain.hearth`, iOS and macOS (Universal Purchase). Add tvOS from the app's page (**+ Platform**) before the first Apple TV upload.
- [x] **Xcode signed in** (team Y4M3S6H4NK). Upload path: **local, `scripts/testflight.sh`**, signed by that account. Signed builds with `-allowProvisioningUpdates` registered `com.bhavikjain.hearth` and `com.bhavikjain.hearth.dev` for iOS and macOS, with the iCloud container `iCloud.com.bhavikjain.hearth` and push (team provisioning profiles made by Xcode). The GitHub TestFlight workflow stays in the repo but needs the `testflight` environment secrets before it can run.
- [ ] **A real portal to probe.** Portal URL + MAC (never committed) for `-SourceProbe` — the protocol rows marked "unverified" must be checked against your provider.
- [ ] **Open questions 2–8** in the handoff (stream limit per MAC, name, roles, downloads, Apple TV, Multitrack code sharing).

## Decisions made this build

| Decision | Choice | Why |
| --- | --- | --- |
| Package layout | Core · SourceKit · CatalogKit · HouseholdKit · PlayerKit, plus one package per feature (Home, LiveTV, Library, Profiles, Household, Search, Settings) | Technical spec; separate packages let agents build in parallel without sharing a `.build` |
| Cross-feature navigation | Core's `HearthRoute` + `navigationDestination` in the app; `@Environment(\.play)` with a `PlayIntent` | Features never import each other; the app's playback coordinator owns links, limits, progress |
| Services to views | `CatalogService`, `HouseholdStore`, `ProfileSession` as `@Observable` environment objects | One instance each, value snapshots out |
| Contracts first | Public types and service APIs written before implementation; changes additive only | Lets 6+ agents work at once |
| iPhone Duo | Layout by size class (`\.hearthLayout`), never idiom or orientation; `TabView` sidebar-adaptable; `NavigationSplitView` where regular; no `UIScreen.main`; full-bleed video with controls in the safe area; multiple scenes on | Apple's "Prepare your app for iPhone Duo"; needs Xcode 27.1 / iOS 27.1 SDK for full-screen |
| Orientation | iPhone portrait + landscape (tent mode, player); iPad all four | Duo's outer display honours these; the inner display ignores them |
| Sources in v0.1 | Stalker first and fully; Xtream and M3U clients too, since the protocol work is shared | The owner's provider is a Stalker portal |
| Profiles in v0.1 | Pulled forward from Phase 3: profiles, PIN, Kids, Guest, per-profile favorites/progress | Asked for in this build |
| Tests | Deferred: build the app first, write tests later (owner, 2026-10-25). Phase A's kit tests stay; Phase B adds none | Get a working app on TestFlight sooner |

## Workstreams

Status: ☐ not started · ◐ in progress · ☑ done · ⚠ blocked

| # | Workstream | Owns | Requirements | Status |
| --- | --- | --- | --- | --- |
| 0 | Scaffold and contracts | `project.yml`, all `Package.swift`, contract files | — | ☑ |
| 1 | SourceKit | `Packages/SourceKit` | SRC-1, SRC-2, SRC-3, SRC-4, PRIV-2 | ☑ merged (128 tests) |
| 2 | CatalogKit | `Packages/CatalogKit` | SRC-6, SRC-7, LIV-1/2/6, VOD-1, SER-1, SRCH-1/2, FAV-2 | ☑ merged (33 tests) |
| 3 | HouseholdKit | `Packages/HouseholdKit` | HH-1…7, PRF-1…9, FAV-1/3/4, VOD-3, SER-2/3, PAR-1…4, PRIV-3 | ☑ merged (93 tests in its worktree; hangs on the merged branch — see log) |
| 4 | PlayerKit | `Packages/PlayerKit` | PLY-1…7 (8, 9 later) | ☑ merged (VLCKit 4.0.0-a25) |
| 5 | Design system | `Packages/Core`, `App/Resources/Assets.xcassets` | mockups, accessibility bar | ☑ merged (34 tests, icon) |
| 6 | CI and release | `.github/`, `scripts/`, `README.md` | Build, release | ☑ merged |
| 7 | Profiles feature | `Packages/ProfilesFeature` | PRF-1…5, PRF-8 | ☑ merged |
| 8 | Home feature | `Packages/HomeFeature` | HOME-1 | ☑ merged |
| 9 | Live TV feature | `Packages/LiveTVFeature` | LIV-1…7, PLY-9, MAC-5 | ☑ merged |
| 10 | Library feature | `Packages/LibraryFeature` | VOD-1…3, SER-1…3, FAV-3 | ☑ merged |
| 11 | Household feature | `Packages/HouseholdFeature` | HH-2…6, SRC-1…5, SRC-8/9 | ☑ merged |
| 12 | Search and Settings | `Packages/SearchFeature`, `Packages/SettingsFeature` | SRCH-1…3, MAC-4 | ☑ merged |
| 13 | App shell | `App/Sources`, `project.yml` | MAC-1/2/4/6, navigation, playback coordinator, launch args | ☑ merged |
| 14 | Integration | whole tree | both platforms build, tests pass, runs on iPhone / Duo / Mac | ◐ runs on iPhone, Duo, Mac |
| 15 | TestFlight | signing, upload | Distribution | ⚠ owner |
| 16 | Apple TV | `Hearth-tvOS`, `App/Sources/TVRootView.swift`, each feature's `.tv` variant, Core's TV components and shims | TV app (handoff: "later", pulled forward) | ☑ merged (PR #2); runs in the simulator, not yet on a device or TestFlight |

## Next up

1. Owner: add the real Stalker portal in the simulator again with the fixed build (Household → Add a portal; portal URL, MAC, and the serial under Advanced; Test, then Save). Run it with `REAL=YES scripts/run-sim.sh "iPhone 18 Pro"` (no demo, store kept on disk).
2. TestFlight: the iOS Release archive builds and carries the right build number (`scripts/testflight.sh all --no-upload`), but the App Store export fails with "No Accounts" from Claude's shell, sandboxed or not — Xcode's Apple ID session there is expired or unreadable. Owner (app record done): check Xcode → Settings → Accounts (sign in again if asked), then run `scripts/testflight.sh all` from your own Terminal (or archive and Distribute from Xcode's Organizer). iCloud schema: `scripts/cloudkit/init-schema.sh` sent it to Development on 2026-10-27 (Mac mode, `.dev` profile); the owner checked it and deployed it to Production the same day. Next: the `testflight` environment's secrets, then the first upload.
3. Tune AVPlayer's 6 s start timeout against the real provider (Apple's 4K demo stream fell back to VLCKit in the simulator before playing).
4. CI is green on `main`; PR #1 (CI and tests) and PR #2 (Apple TV) are merged, and the `testflight` environment has its five secrets. The TestFlight workflow and `scripts/testflight.sh` archive tvOS too (branch `testflight-tvos`). Owner: add tvOS to the App Store Connect record (**+ Platform**) before the first Apple TV upload; add branch rules (`main`, `v*`) to the `testflight` environment, which has none yet.

## Session log

### 2026-10-24 — foundation

- Read the handoff package; unpacked it into `docs/handoff/`.
- Xcode updated to 27.1 by the owner; iPhone Duo device type present; iOS 27.1 simulator runtime downloaded with `xcodebuild -downloadPlatform iOS`.
- Wrote `project.yml` (iOS + macOS targets, `.dev` Debug ids, one iCloud container, ATS open for user-supplied servers, background audio/fetch/remote-notification), entitlements, asset catalog skeleton.
- Wrote every package and its public contract: Core (theme, components, routes, play intent, Mac shims), SourceKit models and `SourceClient`, CatalogKit `ItemKey`, values and `CatalogService`, HouseholdKit values, `HouseholdStore`, `ProfileSession`, PlayerKit engine protocol, `PlayerModel`, `PlayerView`, and each feature's entry views. Implementations are placeholders marked `PLACEHOLDER`.
- Both apps build unsigned for iOS Simulator and macOS; the placeholder app launches on the iPhone Duo simulator (`iPhone Duo`, iOS 27.1, 466×678 pt when open; the status bar runs down the right edge).
- The Claude desktop app's simulator side panel shows the iPhone 18 Pro but not the iPhone Duo, even after an app restart; view the Duo in Xcode's **Device Hub** (it has the open/close/rotate controls). Agents drive the Duo headlessly either way.
- Phase A launched as a workflow (`wf_e4b48df7-eed`): workstreams 1–6, one git worktree each, branched from `build/v0.1-foundation`.
- Owner signed in to Xcode. Signed iOS and macOS builds (Release and Debug) registered both bundle ids with iCloud and push.
- Phase A's first run (`wf_e4b48df7-eed`) was cut off by the account's session limit after ~16 min; every agent's partial work was committed as a `WIP <package>` commit on its worktree branch (`worktree-wf_e4b48df7-eed-1` SourceKit … `-6` infra). Resumed as `wf_7ca035c7-b66`, each agent continuing in its existing worktree.
- Second run (`wf_7ca035c7-b66`): infra finished and is merged (tests and TestFlight workflows, `scripts/testflight.sh`, `run-sim.sh`, `run-mac-local.sh`, `codesign-app.sh`, `pick-simulator.sh`, `cloudkit/init-schema.sh`, README). The other five hit the session limit again; their progress is a second `WIP` commit on each branch. Third run resumed at 09:45 on 2026-10-25. `testflight.sh` now numbers builds `yyDDDHHMM` (under 2^31).
- Open for the app shell: `scripts/cloudkit/init-schema.sh` expects the app to print `[CloudKitSchemaInitializer] Schema sent to Development` or `[CloudKitSchemaInitializer] Failed` when run with `-InitializeCloudKitSchema YES`.
- Third run: CatalogKit (33 tests; 50k-movie import ≈ 4 s) and the design system (fonts by PostScript face, ~25 new components, app icon for iOS and macOS, 34 tests) finished and are merged. Core's new `StreamUsage` was renamed `StreamBarUsage` (it clashed with HouseholdKit's contract type in every feature). Both apps build clean for iOS Simulator and macOS. SourceKit, HouseholdKit and PlayerKit were cut off a third time (each now has milestone commits: SourceKit clients + stub + probe, HouseholdKit 90 tests, PlayerKit player screen + multi-view + tests); fourth run started 14:50.
- Known trap, now in CLAUDE.md: `swift test` with an in-tree `.build` fails codesign because `~/Documents` is iCloud-synced; use `--scratch-path` elsewhere.
- Fourth run: SourceKit (Stalker, Xtream, M3U + XMLTV with gzip, demo provider, probe), HouseholdKit (iCloud store, sharing, profiles) and PlayerKit (AVPlayer + VLCKit 4.0.0-a25 from code.videolan.org, player screen, PiP, AirPlay, multi-view) finished and are merged. Both apps build for iOS Simulator and macOS with every kit. SourceKit's 128 tests pass on the merged branch; HouseholdKit's test run hung (idle test process) on the merged branch and was stopped — to investigate when tests resume.
- Owner: build the app first, tests later. Phase B (`hearth-phase-b`) launched without test-writing: Profiles, Home, Live TV, Library, Household, Search + Settings, App shell.
- Phase B's first run (`wf_dda52e4d-b08`) hit the usage limit after ~4.5 min, before any agent wrote code (their empty worktrees were auto-removed). Merged two infra follow-ups (run-sim.sh opens Device Hub; yyDDDHHMM build numbers in the workflow and README). Phase B relaunched at 19:45 as `wf_a1f2311c-a6e`, with agents told to commit a WIP after each milestone so a cut-off keeps their work.
- Phase B second run (`wf_a1f2311c-a6e`) hit the usage limit after ~19 min. Six features left WIP commits (worktrees `wf_a1f2311c-a6e-1`…`-6`: Profiles, Home, Live TV, Library, Household, Search+Settings); the app shell never started (seventh in a six-agent queue). Resumed 2026-10-26 01:20 as `wf_6a88bfbc-e62`: features continue in their worktrees, the app shell starts first in its own worktree `phase-b-appshell`.
- Phase B third run: Profiles, Home, Library and Household finished and are merged; both apps build clean with them. Live TV (3 WIP commits, ~3,800 lines), Search + Settings (5, ~2,500) and the app shell (1, ~1,900) were cut off again and resumed at 06:15 (`wf_6a88bfbc-e62`, same run id, finished agents cached).
- Follow-ups from the finished features (for later): HouseholdKit bulk `progress(profileID:)` read and a public "this device's playback" check; participant pending/accepted status; CatalogKit backdrop artwork and movie director / series cast fields; M3U file playlists stored relative to Application Support; My List reordering UI; the app shell must use HouseholdFeature's public `SourceMapping` (it has a private copy).
- Phase B finished (fourth run): Live TV, Search + Settings and the app shell merged. The whole app builds clean on both platforms.
- First real run, demo provider, in-memory stores: Who's watching (mockup 01), Home (02), the Live TV guide and programme card (03) and the player all work on the iPhone 18 Pro; live playback of Apple's sample stream plays (after the AVPlayer→VLCKit start-timeout fallback). On the iPhone Duo opened (landscape, regular width) the tab bar becomes the Duo's vertical bar with Search/Household/Settings, Home's favorites wrap into a grid. The Mac app launches (ad hoc, no iCloud) with no errors or crash reports; owner to eyeball it (computer-use access was declined).
- Fixed: sidebar-only tabs pushed My List behind "More" on the iPhone (now regular-width only); the demo seed skipped Who's watching.
- Archive check: Info.plist had XcodeGen's literal 1.0 / 1, so every build was version 1.0 build 1 and the script's build-number check stopped the archive; now `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` from project.yml. Second run: archive OK (build 262991058), export fails "No Accounts" / no iOS Distribution certificate / no App Store profile — the export can't use the Xcode Apple ID from Claude's process, even unsandboxed. Upload handed to the owner.
- Owner's real Stalker portal failed in the app though iSTB works. Found by probing it (logins kept out of the repo): (1) the address the provider gives only 301-redirects its root to the real portal host and 404s every API path itself — SourceKit now follows that redirect during discovery; (2) the portal refuses stalkerhek's 64-'f' placeholder device ids ("Device conflict - device_id mismatch") but signs in with blank ones — blank is now the default, placeholder only as a retry; (3) the catalog lists 162,634 VOD titles at 14 per page — CatalogKit now imports whole lists only under 5,000 titles, otherwise each category's first page with on-demand `loadMore` as it's browsed (Library grid wired), and drops movie categories that hold only series. With CatalogKit run against the portal: refresh 78 s, 5,904 channels, 58 movie + 44 show categories, HLS links, guide now/next. iSTB.app wasn't needed.
- Note: an unsigned simulator build (`CODE_SIGNING_ALLOWED=NO`) has no entitlements, and the CloudKit-backed store then crashes at launch ("must have a com.apple.developer.icloud-services entitlement"); demo mode (`-InMemoryStores`) hides it. Use `scripts/run-sim.sh` / Xcode, which sign simulator builds normally.
- Merged the agents' last follow-up commits (Profiles, Home, Household, Library string catalog) and fast-forwarded `main` to the build branch: 115 commits, every worktree branch merged. Both apps build clean. Launched a signed Debug Mac app (development profile, iCloud on, store on disk) and reinstalled a signed simulator build on the iPhone Duo (the unsigned demo build there crashed when opened from its icon).

### 2026-10-26/27 — CI, tests, release runbook, Apple TV started

- Owner asked for CI/CD, tests, TestFlight / secrets / iCloud-schema steps, a CLAUDE.md, and the Apple TV app in parallel.
- Apple TV: separate session `hearth-tvos` on its own worktree branch from `main` (tvOS target, focus UI, top shelf icon).
- HouseholdKit's hanging suite was a Core Data first-touch deadlock between parallel tests (main thread initialising `NSManagedObjectID` for two stored properties while another thread built `HouseholdModel.shared`); fixed by building the model first in `HouseholdStore.init`. 93 tests pass.
- Tests: four agents wrote suites for every feature package plus an app-hosted `HearthTests` target and tests for the portal fixes; ~1,170 tests in `AllPackageTests`, all passing locally. They surfaced an Xtream regression in the new browse rule (a whole list in one answer over 5,000 titles was re-fetched by category) — fixed, with a test — plus "1 streams in use", and two PlayerKit timing tests that timed out under heavy load (waits now 15 s).
- `docs/RELEASE.md` written (TestFlight setup, `testflight` environment secrets, schema ritual); `.claude/CLAUDE.md` rewritten with everything learned. CI's simulator picker skips the iPhone Duo.
- Branch `ci-and-tests` pushed, PR #1 opened against `main`: the Tests workflow's first run on GitHub passed (packages + iOS app 13 min, Mac app 4 min on the `xcode-27` runner with Xcode 27.1), and PR #1 was merged (`f8e8c11`).

### 2026-10-26 — Apple TV

- Branch `claude/apple-tv-58e4a8`, its own session: `Hearth-tvOS` target and `.tvOS(.v18)` on every package; Core shims for what tvOS lacks (file picker, share sheet, stepper, disclosure groups, keyboard shortcuts, drag and drop, text selection) and a `.tv` `HearthLayout`; Core's TV kit (10-foot type, focus button styles, shelves, cards using the system card style); TV variants inside each feature (gate, Home, a paged three-hour Live TV guide built for the focus engine, grids, shelves, movie and show pages, search under tvOS's keyboard, Settings and a read-only Household scaled with Dynamic Type); the player driven by the Siri Remote through focus edges; the layered icon and top shelf from `render-icon.swift`; `scripts/run-tv.sh`; a TV build job in `tests.yml`. Profiles and sources are edited from an iPhone, iPad or Mac; the TV says so. Not yet: a real device, TestFlight for tvOS, multi-view and PiP on the TV, background refresh (the TV refreshes at launch and on becoming active).
- Checked on the Apple TV 4K (3rd generation) simulator with `-InMemoryStores YES -StubProvider YES` (tvOS 27.0 runtime downloaded with `xcodebuild -downloadPlatform tvOS`), driving the remote with the arrow keys: the gate, Home, the guide (focus, paging both ways, select plays), the player (Apple's sample stream, controls focus on select), Movies and a show page. The iOS and Mac schemes still build.
- Brought up to date with `main` after PR #1 (no conflicts beyond this file: packages carry both `.tvOS(.v18)` and their test targets; `project.yml` has `HearthTests` and `Hearth-tvOS`) as branch `apple-tv`, opened as its own PR so CI builds all three apps.
- PR #2 (Apple TV) passed CI — tests + iOS 10 min, Mac and Apple TV builds 3 min each — and was merged (`f7e80c5`).

### 2026-10-27 — Release set-up and Apple TV uploads

- Owner created the App Store Connect record (iOS + macOS). `scripts/cloudkit/init-schema.sh` sent the household schema to CloudKit Development (Mac mode, signed with the `.dev` profile, one launch); the owner checked the encrypted `CD_Source` fields and deployed it to Production.
- Owner made the API key and development `.p12` and set the `testflight` environment's five secrets (no branch rules on it yet). First TestFlight run (`40610987440`, build 101 from `128daf0`): the Mac job archived, signed and uploaded; the iOS archive signed, but App Store validation refused the upload — "No orientations were specified" (iPad multitasking needs `UISupportedInterfaceOrientations`; the simulator never minded). Added to `project.yml` (iPad all four, iPhone all but upside down); next run uploads it.
- tvOS uploads: `testflight.yml`'s iOS job became a matrix over iOS and Apple TV (same signing: development-signed archive with the fixed certificate, cloud-signed export); `scripts/testflight.sh tv` and `all` = iOS, Mac, Apple TV. A local `tv --no-upload` archive stopped at "No Accounts" from Claude's shell (the known Xcode-session problem), so the first CI run is its real test. It may also need a registered Apple TV for the development profile.
