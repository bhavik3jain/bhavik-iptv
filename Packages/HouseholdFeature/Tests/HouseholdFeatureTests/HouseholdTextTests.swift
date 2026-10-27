import CatalogKit
import Foundation
import HouseholdKit
import SourceKit
import Testing
@testable import HouseholdFeature

// The Household screens' computed text. Dates are fixed (`referenceNow`) and
// formatted dates are compared with `HouseholdFormat`'s own output, so these
// pin which line wins, not how this machine's locale spells a month.

private func record(_ kind: String, name: String = "Provider", expiresAt: Date? = nil, credentials: SourceCredentials = SourceCredentials()) -> SourceRecord {
    SourceRecord(name: name, kindRaw: kind, expiresAt: expiresAt, credentials: credentials)
}

private func state(_ phase: SourceRefreshState.Phase = .idle, account: AccountInfo? = nil, catalogAgo: TimeInterval? = nil, guideAgo: TimeInterval? = nil, channels: Int = 0, movies: Int = 0, series: Int = 0) -> SourceRefreshState {
    SourceRefreshState(
        sourceID: UUID(), phase: phase, account: account,
        catalogRefreshedAt: catalogAgo.map { referenceNow - $0 },
        guideRefreshedAt: guideAgo.map { referenceNow - $0 },
        channelCount: channels, movieCount: movies, seriesCount: series
    )
}

/// `HouseholdFormat`: short dates and "2 h ago".
@Suite struct HouseholdFormatTests {
    let britain = Locale(identifier: "en_GB")

    @Test func datesInAPinnedLocaleAndZone() {
        let date = utc(2027, 3, 12)
        #expect(HouseholdFormat.monthYear(date, locale: britain, calendar: gregorianUTC, timeZone: utcZone) == "Mar 2027")
        #expect(HouseholdFormat.day(date, locale: britain, calendar: gregorianUTC, timeZone: utcZone) == "12 Mar 2027")
    }

    @Test func theZoneDecidesTheDay() {
        // 23:30 UTC on 31 March is already April in Tokyo.
        let late = utc(2027, 3, 31, 23, 30)
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(HouseholdFormat.monthYear(late, locale: britain, calendar: gregorianUTC, timeZone: utcZone) == "Mar 2027")
        #expect(HouseholdFormat.monthYear(late, locale: britain, calendar: gregorianUTC, timeZone: tokyo) == "Apr 2027")
        #expect(HouseholdFormat.day(late, locale: britain, calendar: gregorianUTC, timeZone: tokyo) == "1 Apr 2027")
    }

    @Test(arguments: [
        (0.0, "just now"),
        (59, "just now"),
        (60, "1 min ago"),
        (3_599, "59 min ago"),
        (3_600, "1 h ago"),
        (86_399, "23 h ago"),
        (86_400, "1 d ago"),
        (10 * 86_400, "10 d ago"),
        (-3_600, "just now"), // a date in the future (another device's clock)
    ] as [(TimeInterval, String)])
    func ago(secondsAgo: TimeInterval, text: String) {
        #expect(HouseholdFormat.ago(referenceNow - secondsAgo, now: referenceNow) == text)
    }

    @Test func countsLeaveOutWhatIsNotOffered() {
        #expect(HouseholdFormat.counts(channels: 412, movies: 310, series: 210) == "412 channels · 310 movies · 210 shows")
        #expect(HouseholdFormat.counts(channels: 1, movies: 1, series: 1) == "1 channel · 1 movie · 1 show")
        #expect(HouseholdFormat.counts(channels: 12, movies: 0, series: nil) == "12 channels")
        #expect(HouseholdFormat.counts(channels: nil, movies: 2, series: 0) == "2 movies")
        #expect(HouseholdFormat.counts(channels: 0, movies: 0, series: 0) == nil)
        #expect(HouseholdFormat.counts(channels: nil, movies: nil, series: nil) == nil)
    }
}

/// `SourceExpiry`: which expiry a source shows, and when to write it back (SRC-5).
@Suite struct SourceExpiryTests {
    let recorded = utc(2027, 3, 12)
    let latest = utc(2027, 6, 1)

    @Test func theProvidersLatestWordWins() {
        let saved = record("xtream", expiresAt: recorded)
        #expect(SourceExpiry.effective(record: saved, account: nil) == recorded)
        #expect(SourceExpiry.effective(record: saved, account: AccountInfo(status: .active, expiresAt: latest)) == latest)
        // Active with no end date: unlimited now, whatever was recorded.
        #expect(SourceExpiry.effective(record: saved, account: AccountInfo(status: .active)) == nil)
        // An account read that said nothing useful keeps the recorded date.
        #expect(SourceExpiry.effective(record: saved, account: AccountInfo(status: .unknown)) == recorded)
        #expect(SourceExpiry.effective(record: saved, account: AccountInfo(status: .expired)) == recorded)
    }

    @Test func onlyARealChangeIsWritten() {
        let saved = record("xtream", expiresAt: recorded)
        // No account read: leave it.
        #expect(SourceExpiry.update(record: saved, account: nil) == nil)
        // Within a minute of what's stored: leave it.
        #expect(SourceExpiry.update(record: saved, account: AccountInfo(status: .active, expiresAt: recorded + 59)) == nil)
        // Moved: write the new date.
        #expect(SourceExpiry.update(record: saved, account: AccountInfo(status: .active, expiresAt: recorded + 60)) == .some(recorded + 60))
        // Made unlimited: write nil.
        #expect(SourceExpiry.update(record: saved, account: AccountInfo(status: .active)) == .some(nil))
        // Nothing stored, nothing given.
        #expect(SourceExpiry.update(record: record("xtream"), account: AccountInfo(status: .active)) == nil)
        // Nothing stored, a date given.
        #expect(SourceExpiry.update(record: record("xtream"), account: AccountInfo(status: .active, expiresAt: latest)) == .some(latest))
    }
}

/// `SourceRowText`: a source's row on Household (SRC-5, SRC-8).
@Suite struct SourceRowTextTests {
    func row(_ record: SourceRecord, _ state: SourceRefreshState? = nil, canSeeLogins: Bool = true) -> SourceRowText {
        SourceRowText(record: record, state: state, canSeeLogins: canSeeLogins, now: referenceNow)
    }

    @Test func codesAndTitles() {
        #expect(row(record("stalker")).code == "MAC")
        #expect(row(record("xtream")).code == "XC")
        #expect(row(record("m3u")).code == "M3U")
        #expect(row(record("hologram")).code == "?")
        #expect(row(record("m3u", name: "")).title == "Untitled source")
        #expect(row(record("m3u", name: "Family")).title == "Family")
    }

    @Test func aWatcherNeverSeesTheMAC() {
        let portal = record("stalker", credentials: SourceCredentials(macAddress: "00:1A:79:12:34:41"))
        #expect(row(portal).subtitle == "Portal · 00:1A:79:••:••:41")
        #expect(row(portal, canSeeLogins: false).subtitle == "Portal")
        #expect(row(record("stalker")).subtitle == "Portal")
    }

    @Test func subtitles() {
        #expect(row(record("xtream")).subtitle == "Xtream login")
        #expect(row(record("xtream"), state(account: AccountInfo(maxConnections: 1))).subtitle == "Xtream login · 1 stream")
        #expect(row(record("xtream"), state(account: AccountInfo(maxConnections: 2))).subtitle == "Xtream login · 2 streams")
        #expect(row(record("xtream"), state(account: AccountInfo(maxConnections: 0))).subtitle == "Xtream login")

        let web = "https://lists.example.com/list.m3u"
        let file = "file:///Users/someone/Playlists/list.m3u"
        let guide = "https://guide.example.com/epg.xml"
        #expect(row(record("m3u", credentials: SourceCredentials(playlistURL: web, guideURL: guide))).subtitle == "M3U + XMLTV guide")
        #expect(row(record("m3u", credentials: SourceCredentials(playlistURL: web, guideURL: "  "))).subtitle == "M3U playlist")
        #expect(row(record("m3u", credentials: SourceCredentials(playlistURL: file, guideURL: guide))).subtitle == "M3U file + XMLTV guide")
        #expect(row(record("m3u", credentials: SourceCredentials(playlistURL: "FILE:///x.m3u"))).subtitle == "M3U file on one device")
        #expect(row(record("hologram")).subtitle == "Needs a newer version of the app")
    }

    @Test func refreshingBeatsEverything() {
        let expired = record("xtream", expiresAt: referenceNow - day)
        let updating = row(expired, state(.refreshing(progress: 0.404, message: "Movies"), account: AccountInfo(status: .disabled)))
        #expect(updating.status == "Updating\n40%")
        #expect(updating.isRefreshing)
        #expect(!updating.isWarning)
        #expect(row(expired, state(.refreshing(progress: nil, message: ""))).status == "Updating\n…")
    }

    @Test func disabledThenExpiredThenFailed() {
        let future = record("xtream", expiresAt: referenceNow + 30 * day)
        let disabled = row(future, state(.failed(message: "boom"), account: AccountInfo(status: .disabled)))
        #expect(disabled.status == "Disabled")
        #expect(disabled.isWarning)

        // The provider says expired, or the recorded date has passed.
        #expect(row(future, state(.failed(message: "boom"), account: AccountInfo(status: .expired))).status == "Expired")
        let lapsed = row(record("stalker", expiresAt: referenceNow - minute))
        #expect(lapsed.status == "Expired")
        #expect(lapsed.isWarning)

        let failed = row(future, state(.failed(message: "boom")))
        #expect(failed.status == "Couldn't\nupdate")
        #expect(failed.isWarning)
        #expect(!failed.isRefreshing)
    }

    @Test func activeUntilThenUpdatedThenNotYet() {
        let expiry = referenceNow + 60 * day
        let active = row(record("stalker", expiresAt: expiry), state(catalogAgo: 2 * hour))
        #expect(active.status == "Active\nuntil \(HouseholdFormat.monthYear(expiry))")
        #expect(!active.isWarning)
        // A playlist's expiry isn't shown; when it was updated is.
        #expect(row(record("m3u", expiresAt: expiry), state(catalogAgo: 2 * hour)).status == "Updated\n2 h ago")
        #expect(row(record("xtream"), state(catalogAgo: 12 * minute)).status == "Updated\n12 min ago")
        #expect(row(record("xtream")).status == "Not updated\nyet")
        #expect(row(record("xtream"), state()).status == "Not updated\nyet")
    }

    @Test func theProvidersUnlimitedAccountHidesARecordedDate() {
        // Recorded as expiring, but the provider now says active with no end.
        let row = row(record("xtream", expiresAt: referenceNow - day), state(account: AccountInfo(status: .active), catalogAgo: hour))
        #expect(row.status == "Updated\n1 h ago")
        #expect(!row.isWarning)
    }
}

/// `SourceStatusText`: the top of a saved source's editor (SRC-5, SRC-6).
@Suite struct SourceStatusTextTests {
    func status(_ record: SourceRecord, _ state: SourceRefreshState?) -> SourceStatusText {
        SourceStatusText(record: record, state: state, now: referenceNow)
    }

    @Test func refreshingShowsTheStepAndPercent() {
        let text = status(record("stalker", expiresAt: referenceNow - day), state(.refreshing(progress: 0.4, message: "Downloading channels")))
        #expect(text.headline == "Downloading channels · 40%")
        #expect(text.isRefreshing)
        #expect(!text.isWarning) // expiry waits until the refresh is done
        #expect(status(record("stalker"), state(.refreshing(progress: nil, message: "  "))).headline == "Updating…")
    }

    @Test func aFailureKeepsTheProvidersWords() {
        let text = status(record("stalker"), state(.failed(message: "Server busy, try later")))
        #expect(text.headline == "Couldn't update")
        #expect(text.failure == "Server busy, try later")
        #expect(text.isWarning)
        #expect(!text.isRefreshing)

        // Expired is the better headline; the failure still shows below.
        let expired = status(record("stalker", expiresAt: referenceNow - day), state(.failed(message: "Server busy, try later")))
        #expect(expired.headline == "Expired on \(HouseholdFormat.day(referenceNow - day))")
        #expect(expired.failure == "Server busy, try later")
    }

    @Test func headlines() {
        #expect(status(record("stalker"), nil).headline == "Not downloaded on this device yet")
        #expect(status(record("stalker"), state()).headline == "Not downloaded on this device yet")
        let disabled = status(record("xtream"), state(account: AccountInfo(status: .disabled)))
        #expect(disabled.headline == "The provider has disabled this login")
        #expect(disabled.isWarning)
        #expect(status(record("xtream"), state(account: AccountInfo(status: .expired))).headline == "Expired")

        let expiry = referenceNow + 60 * day
        let active = status(record("xtream", expiresAt: expiry), state(account: AccountInfo(status: .active, expiresAt: expiry)))
        #expect(active.headline == "Active until \(HouseholdFormat.day(expiry))")
        #expect(!active.isWarning)
        #expect(status(record("xtream"), state(account: AccountInfo(status: .active))).headline == "Active")
        // Downloaded but the account never said: it signed in, so it's active.
        #expect(status(record("m3u"), state(catalogAgo: hour)).headline == "Active")
    }

    @Test func detailAndUpdatedLines() {
        let downloaded = status(record("stalker"), state(catalogAgo: 2 * hour, guideAgo: 20 * minute, channels: 412, movies: 310, series: 210))
        #expect(downloaded.detail == "412 channels · 310 movies · 210 shows")
        #expect(downloaded.updated == "Catalog updated 2 h ago · guide 20 min ago")

        // Counts only once this device has downloaded the catalog.
        let never = status(record("stalker"), state(channels: 5))
        #expect(never.detail == nil)
        #expect(never.updated == nil)
        #expect(status(record("stalker"), state(catalogAgo: 30)).updated == "Catalog updated just now")
    }
}

/// `TestResultText`: the account lines under a test result (SRC-4).
@Suite struct TestResultTextTests {
    func lines(_ account: AccountInfo?, kind: SourceKind = .xtream) -> [TestResultText.Line] {
        TestResultText.accountLines(account, kind: kind, now: referenceNow)
    }

    @Test func noAccountNoLines() {
        #expect(lines(nil).isEmpty)
        #expect(lines(AccountInfo(status: .unknown)).isEmpty)
    }

    @Test func expiry() {
        let past = referenceNow - day
        let future = referenceNow + 60 * day
        #expect(lines(AccountInfo(status: .expired, expiresAt: past)) == [.init(text: "Expired on \(HouseholdFormat.day(past))", isWarning: true)])
        #expect(lines(AccountInfo(status: .expired)) == [.init(text: "The provider says this login has expired.", isWarning: true)])
        #expect(lines(AccountInfo(status: .disabled, expiresAt: future)) == [.init(text: "The provider has disabled this login.", isWarning: true)])
        #expect(lines(AccountInfo(status: .active, expiresAt: future)) == [.init(text: "Active until \(HouseholdFormat.day(future))")])
        // "Active" with a date that has passed is expired, whatever the status says.
        #expect(lines(AccountInfo(status: .active, expiresAt: past)) == [.init(text: "Expired on \(HouseholdFormat.day(past))", isWarning: true)])
        #expect(lines(AccountInfo(status: .unknown, expiresAt: future)) == [.init(text: "Active until \(HouseholdFormat.day(future))")])
        #expect(lines(AccountInfo(status: .active)) == [.init(text: "Active, no end date given")])
    }

    @Test func trialAndXtreamsStreamCount() {
        #expect(lines(AccountInfo(status: .active, isTrial: true)).map(\.text) == ["Active, no end date given", "A trial login"])
        #expect(lines(AccountInfo(status: .unknown, maxConnections: 1)).map(\.text) == ["1 stream allowed at once"])
        #expect(lines(AccountInfo(status: .unknown, maxConnections: 3, activeConnections: 2)).map(\.text) == ["3 streams allowed at once · 2 in use now"])
        #expect(lines(AccountInfo(status: .unknown, maxConnections: 0)).isEmpty)
        // Only Xtream reports a count.
        #expect(lines(AccountInfo(status: .unknown, maxConnections: 3), kind: .stalker).isEmpty)
    }
}

/// `StreamCaption`: who is using a source's streams (HH-5, MAC-1).
@Suite struct StreamCaptionTests {
    let anya = ProfileRecord(name: "Anya")
    let ben = ProfileRecord(name: "Ben")
    let sourceID = UUID()

    func playback(_ device: String, _ profile: ProfileRecord?, title: String = "Lantern Drama", startedAgo: TimeInterval = 0) -> PlaybackRecord {
        PlaybackRecord(deviceName: device, profileID: profile?.id ?? UUID(), sourceID: sourceID, itemKey: title, title: title, startedAt: referenceNow - startedAgo, lastSeenAt: referenceNow)
    }

    @Test func oneLinePerStream() {
        #expect(StreamCaption.lines([], profiles: [anya]) == nil)
        let caption = StreamCaption.lines(
            [playback("Living Room iPad", anya), playback("Kitchen Mac", nil, title: "Cityline News"), playback(" ", ben, title: "")],
            profiles: [anya, ben]
        )
        #expect(caption == "Anya · Living Room iPad · Lantern Drama\nKitchen Mac · Cityline News\nBen")
    }

    @Test func aRepeatedProfileIDTakesTheFirstName() {
        var twin = ben
        twin.id = anya.id
        #expect(StreamCaption.lines([playback("iPad", anya)], profiles: [anya, twin]) == "Anya · iPad · Lantern Drama")
    }

    @Test func thisDeviceFirstThenOthersInTheOrderTheyStarted() {
        let playbacks = [
            playback("Mac", ben, startedAgo: minute),
            playback("iPad", anya, startedAgo: hour),
            playback("This Mac", anya, startedAgo: 0),
            playback("Mac", ben, startedAgo: 2 * minute), // the same entry twice
        ]
        let caption = StreamCaption.devices(playbacks, profiles: [anya, ben], thisDevice: "This Mac")
        #expect(caption == ["This device", "Anya on iPad", "Ben on Mac"].formatted(.list(type: .and)))
        #expect(StreamCaption.devices([], profiles: [], thisDevice: "This Mac") == nil)
        #expect(StreamCaption.devices([playback("This Mac", anya)], profiles: [anya], thisDevice: "This Mac") == "This device")
    }

    @Test func deviceEntries() {
        #expect(StreamCaption.deviceEntry(device: "iPad", profile: "Anya") == "Anya on iPad")
        // Named after its person already.
        #expect(StreamCaption.deviceEntry(device: "Anya's iPad", profile: "anya") == "Anya's iPad")
        #expect(StreamCaption.deviceEntry(device: "", profile: "Anya") == "Anya")
        #expect(StreamCaption.deviceEntry(device: " iPad ", profile: nil) == "iPad")
        #expect(StreamCaption.deviceEntry(device: "iPad", profile: "  ") == "iPad")
        #expect(StreamCaption.deviceEntry(device: "", profile: nil) == "another device")
    }
}
