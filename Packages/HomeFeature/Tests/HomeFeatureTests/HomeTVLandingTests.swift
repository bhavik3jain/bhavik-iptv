import Testing
@testable import HomeFeature

/// Down from the Apple TV's tab bar on Home (the owner, 2026-11-10: the
/// remote went to the profile menu in the far corner). It lands on the
/// first thing to watch, top to bottom.
@Suite struct HomeTVLandingTests {
    @Test func anotherDevicesOfferComesFirst() {
        #expect(HomeTVLanding.target(offerID: "offer", hasHero: true, hasChannels: true) == .continueOffer("offer"))
    }

    @Test func thenResume() {
        #expect(HomeTVLanding.target(offerID: nil, hasHero: true, hasChannels: true) == .resume)
    }

    /// Nothing to continue: the first favorite channel, not the corner.
    @Test func thenTheFirstFavoriteChannel() {
        #expect(HomeTVLanding.target(offerID: nil, hasHero: false, hasChannels: true) == .firstChannel)
    }

    @Test func nothingToWatchLeavesItToTheFocusEngine() {
        #expect(HomeTVLanding.target(offerID: nil, hasHero: false, hasChannels: false) == nil)
    }
}
