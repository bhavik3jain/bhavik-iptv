import Testing
@testable import Core

@Test func monogramTakesFirstLetters() {
    #expect(Monogram.initials(for: "Cityline News", maxLetters: 2) == "CN")
    #expect(Monogram.initials(for: "Bhavik", maxLetters: 1) == "B")
    #expect(Monogram.initials(for: "", maxLetters: 2) == "?")
}

@Test func countedPicksTheNoun() {
    #expect(counted(1, "stream") == "1 stream")
    #expect(counted(2, "stream") == "2 streams")
    #expect(counted(3, "category", plural: "categories") == "3 categories")
}

@Test func durationsReadLikeTheMockups() {
    #expect(HearthFormat.duration(48 * 60) == "48 min")
    #expect(HearthFormat.duration(65 * 60) == "1 h 5 min")
    #expect(HearthFormat.timecode(-252, signed: true) == "-4:12")
}
