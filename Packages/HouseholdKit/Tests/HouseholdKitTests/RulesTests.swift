import Testing
@testable import HouseholdKit

@Test func pinHashIsSaltedAndStable() {
    let salt = PINHasher.makeSalt()
    #expect(PINHasher.hash(pin: "1234", salt: salt) == PINHasher.hash(pin: "1234", salt: salt))
    #expect(PINHasher.hash(pin: "1234", salt: salt) != PINHasher.hash(pin: "1234", salt: PINHasher.makeSalt()))
    #expect(PINHasher.isValidPIN("0042"))
    #expect(!PINHasher.isValidPIN("42"))
}

@Test func adultCategoriesMatchByName() {
    #expect(AdultContentFilter.isAdult(categoryName: "XXX Adult"))
    #expect(AdultContentFilter.isAdult(categoryName: "18+ Movies"))
    #expect(!AdultContentFilter.isAdult(categoryName: "Kids"))
}
