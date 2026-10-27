import Foundation
import HouseholdKit
import Testing
@testable import ProfilesFeature

/// A household: two adults with PINs, one without, a child (with and without
/// a PIN of their own) and a guest.
struct Household {
    let mum = ProfileRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Mum", kind: .standard, hasPIN: true)
    let dad = ProfileRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Dad", kind: .standard, hasPIN: true)
    let gran = ProfileRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Gran", kind: .standard, hasPIN: false)
    let kid = ProfileRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "Leo", kind: .kids, hasPIN: false)
    let lockedKid = ProfileRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, name: "Mia", kind: .kids, hasPIN: true)
    let guest = ProfileRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, name: "Guest", kind: .guest, hasPIN: true)

    var all: [ProfileRecord] { [mum, dad, gran, kid, lockedKid, guest] }
}

@Suite struct PINStepsTests {
    let home = Household()

    @Test func adultsAreStandardProfilesWithAPIN() {
        #expect(PINSteps.adultsWithPIN(in: home.all).map(\.name) == ["Mum", "Dad"])
        #expect(PINSteps.adultsWithPIN(in: [home.gran, home.kid, home.lockedKid, home.guest]).isEmpty)
    }

    @Test func anUnlockedProfileNeedsNothing() {
        #expect(PINSteps.forSwitch(from: home.mum, to: home.gran, profiles: home.all).isEmpty)
        #expect(PINSteps.forSwitch(from: nil, to: home.kid, profiles: home.all).isEmpty)
        #expect(PINSteps.forSwitch(from: home.mum, to: nil, profiles: home.all).isEmpty)
    }

    @Test func aLockedProfileNeedsItsOwnPIN() {
        let steps = PINSteps.forSwitch(from: home.gran, to: home.dad, profiles: home.all)
        #expect(steps.count == 1)
        #expect(steps.first?.purpose == .profile)
        #expect(steps.first?.profileIDs == [home.dad.id])
        #expect(steps.first?.avatar == home.dad)
        #expect(steps.first?.title == "Enter Dad’s PIN")
        #expect(steps.first?.message == nil)
    }

    @Test func reopeningTheProfileAlreadyOpenNeedsNothing() {
        #expect(PINSteps.forSwitch(from: home.dad, to: home.dad, profiles: home.all).isEmpty)
    }

    @Test func leavingKidsNeedsAnAdultsPIN() throws {
        let steps = PINSteps.forSwitch(from: home.kid, to: home.gran, profiles: home.all)
        #expect(steps.count == 1)
        let step = try #require(steps.first)
        #expect(step.purpose == .adult)
        #expect(step.profileIDs == [home.mum.id, home.dad.id])
        #expect(step.avatar == nil)
        #expect(step.title == "Enter an adult’s PIN")
        #expect(step.message?.hasPrefix("Leaving Leo needs the PIN of ") == true)
        #expect(step.message?.contains("Mum") == true)
        #expect(step.message?.contains("Dad") == true)
        #expect(step.message?.contains("Gran") == false)
    }

    @Test func leavingKidsForTheGateStillNeedsAnAdult() {
        let steps = PINSteps.forSwitch(from: home.kid, to: nil, profiles: home.all)
        #expect(steps.map(\.purpose) == [.adult])
    }

    @Test func anAdultOpeningTheirOwnLockedProfileProvesBothAtOnce() {
        let steps = PINSteps.forSwitch(from: home.kid, to: home.mum, profiles: home.all)
        #expect(steps.count == 1)
        #expect(steps.first?.purpose == .profile)
        #expect(steps.first?.profileIDs == [home.mum.id])
    }

    @Test func leavingKidsForAnotherLockedChildTakesAnAdultThenTheChild() {
        let steps = PINSteps.forSwitch(from: home.kid, to: home.lockedKid, profiles: home.all)
        #expect(steps.map(\.purpose) == [.adult, .profile])
        #expect(steps.last?.profileIDs == [home.lockedKid.id])
    }

    @Test func leavingKidsForALockedGuestTakesAnAdultThenTheGuest() {
        let steps = PINSteps.forSwitch(from: home.kid, to: home.guest, profiles: home.all)
        #expect(steps.map(\.purpose) == [.adult, .profile])
    }

    @Test func aChildsOwnPINNeverLetsThemOut() {
        // Only the locked child and a guest have PINs: no adult can agree,
        // so nothing is asked (rather than a step nobody can pass).
        let profiles = [home.gran, home.lockedKid, home.guest]
        #expect(PINSteps.forSwitch(from: home.lockedKid, to: home.gran, profiles: profiles).isEmpty)
    }

    @Test func withNoAdultPINsLeavingKidsOnlyNeedsTheTargetsPIN() {
        let profiles = [home.gran, home.kid, home.lockedKid]
        #expect(PINSteps.forSwitch(from: home.kid, to: home.gran, profiles: profiles).isEmpty)
        #expect(PINSteps.forSwitch(from: home.kid, to: home.lockedKid, profiles: profiles).map(\.purpose) == [.profile])
    }

    @Test func managingProfilesNeedsAnAdultWhenAnyAdultHasAPIN() {
        let steps = PINSteps.forManaging(profiles: home.all)
        #expect(steps.count == 1)
        #expect(steps.first?.purpose == .adult)
        #expect(steps.first?.profileIDs == [home.mum.id, home.dad.id])
        #expect(steps.first?.message?.hasPrefix("Changing profiles needs the PIN of ") == true)
        #expect(PINSteps.forManaging(profiles: [home.gran, home.lockedKid, home.guest]).isEmpty)
    }

    @Test func stepIDsNameThePurposeAndProfiles() {
        let adult = PINSteps.forManaging(profiles: home.all)[0]
        #expect(adult.id == "adult-\(home.mum.id.uuidString),\(home.dad.id.uuidString)")
        let own = PINSteps.forSwitch(from: nil, to: home.dad, profiles: home.all)[0]
        #expect(own.id == "profile-\(home.dad.id.uuidString)")
    }
}

@Suite struct PINEntryStateTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Types `pin` at `date`, returning what the last digit returned.
    @discardableResult
    private func type(_ pin: String, into state: inout PINEntryState, at date: Date) -> String? {
        var result: String?
        for digit in pin { result = state.append(digit, at: date) }
        return result
    }

    private func reject(_ times: Int, _ state: inout PINEntryState, at date: Date) {
        for _ in 0..<times {
            type("0000", into: &state, at: date)
            state.resolve(.rejected, at: date)
        }
    }

    @Test func theFourthDigitCompletesThePIN() {
        var state = PINEntryState()
        #expect(state.append("1", at: start) == nil)
        #expect(state.append("2", at: start) == nil)
        #expect(state.append("3", at: start) == nil)
        #expect(state.phase == .entering)
        #expect(state.append("4", at: start) == "1234")
        #expect(state.phase == .checking)
        #expect(state.digits == "1234")
    }

    @Test(arguments: ["a", " ", "-", "٣", "５"] as [Character])
    func onlyASCIIDigitsAreTyped(character: Character) {
        var state = PINEntryState()
        #expect(state.append(character, at: start) == nil)
        #expect(state.digits.isEmpty)
    }

    @Test func nothingIsTypedWhileTheOwnerChecks() {
        var state = PINEntryState()
        type("1234", into: &state, at: start)
        #expect(!state.canType(at: start))
        #expect(state.append("5", at: start) == nil)
        state.deleteLast()
        #expect(state.digits == "1234")
    }

    @Test func deleteRemovesTheLastDigit() {
        var state = PINEntryState()
        type("12", into: &state, at: start)
        state.deleteLast()
        #expect(state.digits == "1")
        state.deleteLast()
        state.deleteLast()
        #expect(state.digits.isEmpty)
    }

    @Test func acceptedKeepsTheDots() {
        var state = PINEntryState()
        type("1234", into: &state, at: start)
        state.resolve(.accepted, at: start)
        #expect(state.phase == .accepted)
        #expect(state.digits == "1234")
        #expect(!state.canType(at: start))
    }

    @Test func nextClearsWithoutAShake() {
        var state = PINEntryState()
        type("1234", into: &state, at: start)
        state.resolve(.next, at: start)
        #expect(state.phase == .entering)
        #expect(state.digits.isEmpty)
        #expect(state.shakes == 0)
        #expect(state.failedTries == 0)
        #expect(!state.showsWrongPIN)
    }

    @Test func aMismatchShakesButIsNotAWrongTry() {
        var state = PINEntryState()
        type("1234", into: &state, at: start)
        state.resolve(.mismatched, at: start)
        #expect(state.digits.isEmpty)
        #expect(state.phase == .entering)
        #expect(state.shakes == 1)
        #expect(state.failedTries == 0)
        #expect(!state.showsWrongPIN)
        #expect(state.lockedUntil == nil)
    }

    @Test func aWrongPINShakesCountsAndSaysSo() {
        var state = PINEntryState()
        reject(1, &state, at: start)
        #expect(state.digits.isEmpty)
        #expect(state.phase == .entering)
        #expect(state.shakes == 1)
        #expect(state.failedTries == 1)
        #expect(state.showsWrongPIN)
        #expect(state.lockedUntil == nil)
        // The next digit takes the message away.
        _ = state.append("7", at: start)
        #expect(!state.showsWrongPIN)
    }

    @Test func fourWrongTriesDontLock() {
        var state = PINEntryState()
        reject(4, &state, at: start)
        #expect(!state.isLocked(at: start))
        #expect(state.canType(at: start))
    }

    @Test func theFifthWrongTryLocksForThirtySeconds() {
        var state = PINEntryState()
        reject(5, &state, at: start)
        #expect(state.failedTries == 5)
        #expect(state.lockedUntil == start.addingTimeInterval(30))
        #expect(state.isLocked(at: start))
        #expect(state.isLocked(at: start.addingTimeInterval(29.9)))
        #expect(!state.isLocked(at: start.addingTimeInterval(30)))
        #expect(!state.canType(at: start.addingTimeInterval(10)))
        #expect(state.canType(at: start.addingTimeInterval(30)))
    }

    @Test func digitsAreIgnoredDuringTheCooldown() {
        var state = PINEntryState()
        reject(5, &state, at: start)
        #expect(state.append("1", at: start.addingTimeInterval(5)) == nil)
        #expect(state.digits.isEmpty)
    }

    @Test func secondsLeftRoundUp() {
        var state = PINEntryState()
        #expect(state.secondsLeft(at: start) == nil)
        reject(5, &state, at: start)
        #expect(state.secondsLeft(at: start) == 30)
        #expect(state.secondsLeft(at: start.addingTimeInterval(0.2)) == 30)
        #expect(state.secondsLeft(at: start.addingTimeInterval(29.5)) == 1)
        #expect(state.secondsLeft(at: start.addingTimeInterval(30)) == nil)
        #expect(state.secondsLeft(at: start.addingTimeInterval(45)) == nil)
    }

    @Test func endingTheCooldownOnlyOnceItHasRunOut() {
        var state = PINEntryState()
        reject(5, &state, at: start)
        state.endCooldown(at: start.addingTimeInterval(29))
        #expect(state.lockedUntil != nil)
        #expect(state.showsWrongPIN)
        state.endCooldown(at: start.addingTimeInterval(30))
        #expect(state.lockedUntil == nil)
        #expect(!state.showsWrongPIN)
    }

    @Test func everyFifthWrongTryLocksAgain() {
        var state = PINEntryState()
        let later = start.addingTimeInterval(60)
        reject(5, &state, at: start)
        state.endCooldown(at: later)
        reject(4, &state, at: later)
        #expect(!state.isLocked(at: later))
        reject(1, &state, at: later)
        #expect(state.failedTries == 10)
        #expect(state.lockedUntil == later.addingTimeInterval(30))
    }
}

@Suite struct PINSetupStateTests {
    @Test func typeThenConfirm() {
        var setup = PINSetupState()
        #expect(!setup.isConfirming)
        #expect(setup.submit("2580") == .confirmNext)
        #expect(setup.isConfirming)
        #expect(setup.submit("2580") == .done("2580"))
    }

    @Test func aMismatchStartsOver() {
        var setup = PINSetupState()
        _ = setup.submit("2580")
        #expect(setup.submit("2581") == .mismatch)
        #expect(!setup.isConfirming)
        #expect(setup.mismatched)
        // The first PIN is forgotten: the next entry is a fresh first entry.
        #expect(setup.submit("1111") == .confirmNext)
        #expect(!setup.mismatched)
        #expect(setup.submit("2580") == .mismatch)
        #expect(setup.submit("1111") == .confirmNext)
        #expect(setup.submit("1111") == .done("1111"))
    }
}
