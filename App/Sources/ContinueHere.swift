import CatalogKit
import Core
import Foundation
import HouseholdKit
import PlayerKit

// Continue on Apple TV (docs/designs/continue-on-tv.md), the app's side.
//
// On the device carrying on (the TV's Home offers it): `continueHere` checks
// it can play the thing, ends the other device's who's-watching rows — which
// frees their streams at once — and plays the same channel, multi-view, or
// movie or episode from the profile's progress, moving on to the other
// device's last position if it lands within a minute.
//
// On every device: when another device has carried on what plays here, the
// player (or multi-view kept in the background) stops, with a word saying
// where it went. On-screen multi-view does the same for itself.

extension PlaybackCoordinator {
    /// `\.continueHere`.
    func continueHere(_ request: ContinueHereRequest, sceneID: UUID?, layout: HearthLayout) {
        if let sceneID { lastSceneID = sceneID }
        guard let profile = session.currentProfile else { return }
        let scene = sceneID ?? lastSceneID
        switch request.content {
        case .play(let intent):
            // Nothing ends on the other device unless this one can play it.
            guard PlayerItemFactory(catalog: catalog, store: store, profileID: profile.id).prepare(intent) != nil else {
                notice = ContinueHereText.cantPlay(intent.title, device: request.deviceName, sceneID: scene)
                return
            }
            let baseline = store.progress(profileID: profile.id, itemKey: intent.itemKey)?.updatedAt
            store.endPlaybacks(request.endingPlaybackIDs)
            play(intent, sceneID: scene, layout: layout)
            if intent.kind == .movie || intent.kind == .episode, !profile.isGuest {
                followHandoffPosition(itemKey: intent.itemKey, profileID: profile.id, since: baseline)
            }

        case .multiView(let keys):
            let available = keys.filter { catalog.channel(ItemKey(rawValue: $0)) != nil }
            guard !available.isEmpty else {
                notice = ContinueHereText.cantPlay(String(localized: "Multi-view"), device: request.deviceName, sceneID: scene)
                return
            }
            store.endPlaybacks(request.endingPlaybackIDs)
            // One thing at a time, and these tiles rather than any kept ones.
            closeCurrent()
            multiViewBackground.stop(store: store)
            multiViewStartingChannelKeys = available
            multiViewSceneID = scene
        }
    }

    /// The other device saves its position as it stops, which reaches this
    /// one a few seconds after this player opened from the older one: move
    /// on to it (`HandoffResume`). Given up after a minute, or when the
    /// player shows something else.
    func followHandoffPosition(itemKey: String, profileID: UUID, since baseline: Date?) {
        handoffFollow?.cancel()
        handoffFollow = Task { [weak self] in
            let deadline = ContinuousClock.now + HandoffResume.window
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: HandoffResume.pollInterval)
                guard !Task.isCancelled, let self else { return }
                // The player may still be opening (a stream-limit check).
                guard let playing = self.current, playing.model.item.id == itemKey,
                      playing.model.state == .playing || playing.model.state == .paused,
                      let row = self.store.progress(profileID: profileID, itemKey: itemKey) else { continue }
                if let target = HandoffResume.seekTarget(row, since: baseline, playerPosition: playing.model.currentTime, duration: playing.model.duration) {
                    playing.model.seek(to: target)
                    return
                }
            }
        }
    }

    /// Another device carried on what plays here: it stops, and says where.
    func stopWhatAnotherDeviceTookOver() {
        if let playing = current, let id = playing.playbackID, let takeover = store.takeover(ofPlaybacks: [id]) {
            let item = playing.model.item
            let scene = playing.sceneID ?? lastSceneID
            handoffFollow?.cancel()
            closeCurrent()
            tellTakenOver(ContinueHereText.takenOver(item.channelName ?? item.title, device: takeover.deviceName, sceneID: scene))
        }
        if let takeover = multiViewBackground.releaseTilesTakenOver(store: store), !multiViewBackground.isRunning {
            tellTakenOver(ContinueHereText.takenOver(String(localized: "Multi-view"), device: takeover.deviceName, sceneID: lastSceneID))
        }
    }

    /// After the full-screen player has gone: an alert asked for while a
    /// cover is still leaving doesn't show.
    private func tellTakenOver(_ message: PlaybackNotice) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            self?.notice = message
        }
    }
}

/// When a movie or episode carried on here moves to the other device's last
/// position.
enum HandoffResume {
    /// The other device stops once it sees this one playing (its push, its
    /// save, the push back): seconds, so a minute is plenty.
    static let window: Duration = .seconds(60)
    static let pollInterval: Duration = .seconds(1)
    /// Closer than this to where the player is, and it isn't worth a jump.
    static let threshold: TimeInterval = 10
    /// Nearer the end than this, and the other device had finished it.
    static let endMargin: TimeInterval = 30

    /// The position to move to: the profile's progress row, saved after this
    /// player opened (`baseline` was the row's time then), unfinished, and
    /// ahead of the player by more than the threshold. Rows this player
    /// saves itself are where it is, so never move it.
    static func seekTarget(_ row: ProgressRecord, since baseline: Date?, playerPosition: TimeInterval, duration: TimeInterval?) -> TimeInterval? {
        if let baseline, row.updatedAt <= baseline { return nil }
        guard !row.watched, row.position > playerPosition + threshold else { return nil }
        let total = duration ?? (row.duration > 0 ? row.duration : nil)
        if let total, row.position >= total - endMargin { return nil }
        return row.position
    }
}

/// What the app says about carrying on.
enum ContinueHereText {
    static func cantPlay(_ title: String, device: String, sceneID: UUID?) -> PlaybackNotice {
        PlaybackNotice(
            sceneID: sceneID,
            title: String(localized: "Can't play this here"),
            message: String(localized: "\(title) isn't available here for this profile, so it keeps playing on \(device).")
        )
    }

    static func takenOver(_ title: String, device: String, sceneID: UUID?) -> PlaybackNotice {
        PlaybackNotice(
            sceneID: sceneID,
            title: String(localized: "Playing on \(device)"),
            message: String(localized: "\(title) carried on there, so it stopped here.")
        )
    }
}
