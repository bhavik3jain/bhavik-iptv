import Testing
@testable import HomeFeature

@Suite struct EpisodeLineTests {
    @Test func subtitleJoinsTheCodeAndARealTitle() {
        #expect(EpisodeLine.subtitle(season: 2, number: 5, title: "The Lighthouse Keeper") == "S2 · E5 — The Lighthouse Keeper")
    }

    @Test(arguments: [nil, "", "   ", "\n", "Episode 5", "S02E05"])
    func subtitleIsTheCodeAloneWhenTheTitleSaysNothing(title: String?) {
        #expect(EpisodeLine.subtitle(season: 2, number: 5, title: title) == "S2 · E5")
    }

    /// Titles that only restate episode 5 in the forms providers send.
    @Test(arguments: ["5", "05", "Episode 5", "episode 05", "EPISODE-5", "Ep. 5", "ep_5", "E05", "e5", "S02E05", "S2 E5", "s2.e5", "S1 Episode 5", "  Episode 5  "])
    func numberOnlyTitlesAreDropped(title: String) {
        #expect(EpisodeLine.meaningfulTitle(title, number: 5) == nil)
    }

    @Test(arguments: ["Episode 6", "E50", "S2", "Se7en", "5 Days Later", "Episode Five", "Season Finale", "Pilot"])
    func realTitlesAreKept(title: String) {
        #expect(EpisodeLine.meaningfulTitle(title, number: 5) == title)
    }

    @Test func keptTitlesAreTrimmed() {
        #expect(EpisodeLine.meaningfulTitle("  The Pilot \n", number: 1) == "The Pilot")
    }

    @Test func aNumberMatchingADifferentEpisodeIsATitle() {
        // "Episode 12" on episode 2 is the provider's own (odd) title, not a
        // restatement of the number, so it stays.
        #expect(EpisodeLine.meaningfulTitle("Episode 12", number: 2) == "Episode 12")
        #expect(EpisodeLine.meaningfulTitle("S01E02", number: 3) == "S01E02")
    }

    @Test func badgeIsCompactAndMarksNewEpisodes() {
        #expect(EpisodeLine.badge(season: 3, number: 3, isNew: false) == "S3 E3")
        #expect(EpisodeLine.badge(season: 3, number: 3, isNew: true) == "New · S3 E3")
        #expect(EpisodeLine.badge(season: 0, number: 12, isNew: false) == "S0 E12")
    }

    @Test func captionFallsBackToTheEpisodeNumber() {
        #expect(EpisodeLine.caption(number: 3, title: "Low Tide") == "Low Tide")
        #expect(EpisodeLine.caption(number: 3, title: nil) == "Episode 3")
        #expect(EpisodeLine.caption(number: 3, title: "E03") == "Episode 3")
        #expect(EpisodeLine.caption(number: 3, title: " ") == "Episode 3")
    }
}
