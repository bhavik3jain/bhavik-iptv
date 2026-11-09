# Continue on Apple TV

*Design, 2026-11-08. The owner's idea: "if I was watching something on my laptop (the Mac app) or my phone (the iOS app) and wanted to continue that same setup on my Apple TV on the profile, it'd be cool to do a 'handoff'."*

## The problem

You're watching a channel on the iPhone, or four channels in multi-view on the Mac, or a movie, and you sit down in front of the TV. Today you open Hearth on the TV, find the same channel(s) again with the remote, and maybe hit the stream limit, because the phone is still holding the portal's only stream ("1 of 1 streams in use: Bhavik on iPhone"). The goal: one press on the TV carries the same thing on, and the other device stops so its stream is free.

## What Apple supports

- **Handoff (`NSUserActivity` continuity) doesn't reach the Apple TV.** As far as I know from Apple's documentation, Handoff works between iPhone, iPad, Mac and Apple Watch; tvOS doesn't take part (no Handoff icon on the TV, no `continueUserActivity` from another device). So the system feature the owner named can't do this.
- **AirPlay** puts the phone's picture on the TV, but the phone keeps the stream, the decoding and the battery drain, and Hearth's TV app isn't involved. The player already has the AirPlay button.
- **The TV app's Up Next / "Continue watching"** is for apps in Apple's video partner programme, which a TestFlight IPTV player isn't.
- **DeviceDiscoveryUI** (tvOS 16+) lets a TV app find and connect to its own companion app on a nearby iPhone or iPad over the local network, with a system picker and a permission prompt. iOS/iPadOS only as far as I know, not the Mac. Worth knowing for phase 2.

So Hearth has to do it itself. It already has what's needed: who's-watching rows and progress rows already sync through iCloud in seconds.

## Options considered

1. **Through iCloud, from the rows we already sync (chosen for phase 1).** Every stream writes a who's-watching row (device name, profile, item, start time, heartbeat). The TV reads the profile's rows from other devices and offers them. No pairing, works for the Mac and the phone alike, and no new entity or attribute, so nothing waits on a CloudKit schema deploy before TestFlight.
2. **A local-network push** ("Send to Apple TV" on the phone/Mac, received by the TV over Bonjour). Instant and precise (exact position, sound tile), but it needs the TV app open, local-network permission on every device, and Mac sandbox entitlements. Phase 2.
3. **A new "handoff request" record in iCloud** (the phone writes "play this on Living Room"). It would let the phone push to a TV that's asleep, but it's a schema change and still needs the TV app to be running to act on it. Not now.

## The choice: phase 1, built

**On the TV's Home**, once a profile is picked (and whenever Home is showing: becoming active, rows arriving), cards above Continue watching: **"On Bhavik's iPhone now"**, with **Continue here**.

- **What's offered** (`HouseholdKit/ContinueHere.swift`, `ContinueOfferRules`, tested): the profile's fresh who's-watching rows (heartbeat under 15 minutes) from other devices, one offer per device and kind, newest first:
  - one channel row → that **channel**;
  - two or more channel rows from one device → its **multi-view**, same channels **in the same tile order** (multi-view now writes its tiles' rows with start times in slot order, 10 ms apart, so the order survives the trip);
  - a movie or episode row → that **video**, open in the player there (playing or paused).
  - Left out: this TV's own rows (by id and by its device name), other profiles, Guests (everyone shares Guest), stale rows, and running downloads (their rows' keys are now marked `#download`).
  - The TV shows a card only if it can play it: the channels are in its catalog for this profile, the movie is, or the episode's show is (`ContinueOfferCards` in HomeFeature, tested). A movie found by search on the phone shows up once the TV's catalog has found it by name (the existing `HeldItems`).
- **Continue here** (`App/Sources/ContinueHere.swift`): checks the TV can play it first (nothing is stopped otherwise), **ends the other device's rows** (so their streams are free immediately, in every device's count, and no stream-limit warning about the phone), then plays: the same channel live; multi-view with the same channels in the same order (as many as the sources have room for); a movie or episode from the profile's saved progress.
- **The other device stops** (`TakeoverRules`, tested): a device whose own row is gone while still fresh (written under 13 minutes ago, so no stale purge took it) **and** sees another device's row for the same profile and item, was taken over. The player closes with "Playing on Living Room — Cityline News carried on there, so it stopped here." Multi-view (on screen or kept in the background) closes the taken-over tiles the same way. If the TV couldn't start, no successor row appears, the other device keeps playing and its next heartbeat writes its row back, as it does after a purge today.
- **Position for a movie or episode:** the phone saves progress on pause, on going to the background and every 5 minutes; and now also as it stops on being taken over. The TV starts from the saved position, and if the phone's final position lands within a minute and is more than 10 seconds ahead, the TV's player moves there (`HandoffResume`, tested).
- The Continue watching hero steps aside when a card offers the same movie or episode (the card says more: where it's playing, and that it'll stop there).
- **A movie or episode already stopped on another device** isn't a separate card: the Continue watching hero already shows the most recent unfinished one from the same synced progress rows and resumes it. Progress rows don't say which device wrote them, so the TV couldn't say "from your iPhone" without a schema change.

Try it in the simulator: `scripts/run-tv.sh "" -SelectProfile Bhavik -SeedContinueOffers YES` (the demo, plus a "MacBook Pro" in multi-view and a "Bhavik's iPhone" with a movie open; they go stale in 15 minutes).

## Limits of phase 1

- **The TV must be open** to see the offer. Nothing pushes to a sleeping TV (option 3 would, with a schema change).
- **Device names:** iOS 16+ gives apps a generic "iPhone" without a special entitlement, so two iPhones show the same name, and two iPhones playing channels for the same profile would look like one multi-view. Rare; the offer still plays the right channels.
- **Catch-up and "From the start"** rows carry the channel's key, so they carry on **live**, not at the programme position.
- **Which multi-view tile had the sound** isn't in the rows; the TV gives it to the first tile.
- **Multi-view older builds** (113 and before) wrote tiles in the order they were filled, not slot order.
- The phone stops only once it hears about the takeover (a CloudKit push, seconds; longer if it's asleep in a pocket). Until then both play; a portal that allows one stream per MAC may cut one of them off itself.
- Not verified on real devices: CloudKit timing between the owner's iPhone, Mac and TV, and whether the phone, paused in the background, gets the push.

## Phase 2: "Send to Apple TV" over the local network (not built)

The phone or Mac player gets a **Send to Apple TV** button; the TV, while Hearth is open, advertises itself and plays what it's sent instantly.

- **TV:** an `NWListener` advertising a Bonjour service (`_hearth._tcp`), only while the app is in the foreground, named after the TV. Accepts one small JSON message: `{householdID, profileID, content: channel | multiView(keys) | video(key, position), soundTile}`.
- **Phone/Mac:** an `NWBrowser` for `_hearth._tcp` listing TVs in the player's menu (beside AirPlay); sending ends its own rows itself, so no waiting for iCloud.
- **Needs:**
  - `NSBonjourServices: [_hearth._tcp]` in the iOS, Mac and tvOS targets' `info:` blocks in `project.yml` (none has it today).
  - `NSLocalNetworkUsageDescription`: iOS and tvOS already have one (for portals on the home network); its wording should mention finding the Apple TV. The Mac target has none, and macOS 15 asks for local-network permission too, so it needs one. iOS shows the permission prompt the first time it browses.
  - Mac sandbox: `com.apple.security.network.client` (already there) is enough to send; `network.server` only if the Mac ever receives. iOS and tvOS have no sandbox network entitlements to add.
  - Only the household's devices accepted: the household's id from iCloud in the message isn't a secret on its own, so TLS with a pre-shared key derived from something only household members hold, or a one-time pairing code shown on the TV.
  - **PIN-protected profiles:** the TV asks for the profile's PIN before playing for it (or plays only when that profile is already the TV's current one), since anyone on the Wi-Fi with Hearth could send to it.
- Alternative: **DeviceDiscoveryUI** from the TV side (the TV pulls from a nearby iPhone/iPad with a system picker). Apple-sanctioned and handles permissions, but no Mac.

## Open questions for the owner

1. Should the TV **ask** before stopping the other device ("Continue here and stop it on your iPhone?"), or is pressing Continue here enough? (Built: enough; the button's hint says it stops there.)
2. Should the phone and Mac offer the same thing in reverse (Continue from Apple TV)? The takeover detection already works on every device; it needs only the offer UI on iOS/Mac Home.
3. Is phase 2 worth the local-network permission prompt on the phone, or is phase 1's few-seconds delay fine?
4. Movies and episodes: carry on from the saved position immediately and jump when the phone's final position arrives (built), or wait a few seconds for it before starting?
