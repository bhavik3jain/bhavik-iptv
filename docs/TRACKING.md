# Hearth — build tracker and handoff log

The single place to see what's built, what's in flight, what's blocked and what comes next. Anyone picking this up (a person or an agent) reads **Status**, **Blocked on the owner** and **Next up**, then the newest **Session log** entry. Update this file at the end of every working session; keep entries short and dated.

Specs live in [docs/handoff](handoff/README.md): the [handoff](handoff/docs/1-Handoff.md), the [product spec](handoff/docs/2-Product-spec.md) (requirement ids such as SRC-1 and PRF-2), the [technical spec](handoff/docs/3-Technical-spec.md) and the [source protocols](handoff/docs/4-Source-protocols.md). Mockups: [handoff/ui/png](handoff/ui/png).

## Status

| | |
| --- | --- |
| Goal | An IPTV player for Stalker portals with Netflix-style profiles, on iPhone (including iPhone Duo), iPad and Mac, installed through TestFlight |
| Version | 0.1 (build numbers come from CI run number + offset) |
| Branch | `build/v0.1-foundation` (main has no commits yet) |
| Toolchain | Xcode 27.1 (27A9275), Swift 6.4, iOS 27.1 SDK; deployment iOS 18 / macOS 15 |
| Bundle ids | `com.bhavikjain.hearth` (release), `com.bhavikjain.hearth.dev` (Debug) · iCloud `iCloud.com.bhavikjain.hearth` · team Y4M3S6H4NK |
| Builds | Scaffold builds for iOS Simulator and macOS (unsigned) |
| TestFlight | Not yet uploaded — local `scripts/testflight.sh` with Xcode's Apple ID (owner signing in, creating the app record) |

## Blocked on the owner

These need you; nothing else waits on them until the upload step.

- [ ] **App Store Connect app record** (owner doing it, on appstoreconnect.apple.com → Apps → + → New App; the bundle id is now registered so it appears in the form): an app named Hearth (or the final name) with bundle id `com.bhavikjain.hearth`, platforms iOS and macOS (Universal Purchase). App Store Connect's API can't create apps.
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
| 7 | Profiles feature | `Packages/ProfilesFeature` | PRF-1…5, PRF-8 | ◐ |
| 8 | Home feature | `Packages/HomeFeature` | HOME-1 | ◐ |
| 9 | Live TV feature | `Packages/LiveTVFeature` | LIV-1…7, PLY-9, MAC-5 | ◐ |
| 10 | Library feature | `Packages/LibraryFeature` | VOD-1…3, SER-1…3, FAV-3 | ◐ |
| 11 | Household feature | `Packages/HouseholdFeature` | HH-2…6, SRC-1…5, SRC-8/9 | ◐ |
| 12 | Search and Settings | `Packages/SearchFeature`, `Packages/SettingsFeature` | SRCH-1…3, MAC-4 | ◐ |
| 13 | App shell | `App/Sources`, `project.yml` | MAC-1/2/4/6, navigation, playback coordinator, launch args | ◐ |
| 14 | Integration | whole tree | both platforms build, tests pass, runs on iPhone / Duo / Mac | ☐ |
| 15 | TestFlight | signing, upload | Distribution | ⚠ owner |

## Next up

1. Phase A (parallel): workstreams 1–6.
2. Phase B (parallel): workstreams 7–13, against the finished kits.
3. Phase C: integration build and fixes, run on iPhone, iPhone Duo and Mac simulators with `-StubProvider YES -InMemoryStores YES`.
4. TestFlight once the owner's items above are done.

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
