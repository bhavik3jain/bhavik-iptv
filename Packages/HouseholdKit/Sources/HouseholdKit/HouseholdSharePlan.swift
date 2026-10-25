import CloudKit
import Foundation

/// How Invite gets from a tap to a household share with a link, as plain
/// values: which step comes next, how long each may take, and what to say
/// when one doesn't come back (HH-2). `HouseholdStore.prepareShare` carries
/// the steps out against the real container; this decides them, so every
/// decision is tested without iCloud. Multitrack's SharePreparationPlan,
/// adapted to one share root.
///
/// What Multitrack's Fuel taught (October 2026), and what each rule here is for:
/// - A lookup that *fails* is not "not shared". Read through `try?`, it was,
///   and every retry called `share()` again: four share zones for one car.
///   So only a lookup that answers "not shared" may lead to `share()`.
/// - `share()` Core Data gave up on can still land in iCloud minutes later.
///   So it runs at most once per preparation; after a failure the plan waits
///   for the next upload and looks again instead of making another.
/// - Before making one, iCloud itself is asked whether an earlier try left a
///   share zone holding the household's record; if one did, nothing is made
///   unless the person says Share Anyway.
/// - Every step has a limit, so the worst case is a message with iCloud's own
///   words and Try Again — never a spinner.
struct HouseholdSharePlan: Sendable, Equatable {
    enum Step: Sendable, Equatable {
        case lookingUp
        case waitingForSync
        case checkingEarlierTries
        case creating
        case saving
        case waitingForUpload
        case fetchingLink
        case ready
        case failed(Failure)

        /// What the invite sheet says while a step runs.
        var statusText: String {
            switch self {
            case .lookingUp: "Checking whether the household is already shared…"
            case .waitingForSync: "Waiting for iCloud to finish syncing…"
            case .checkingEarlierTries: "Checking iCloud for an earlier try…"
            case .creating: "Creating the share in iCloud…"
            case .saving: "Saving the share…"
            case .waitingForUpload: "Waiting for iCloud to finish uploading…"
            case .fetchingLink: "Getting the link from iCloud…"
            case .ready: "Ready"
            case .failed(let failure): failure.title
            }
        }
    }

    enum Action: Sendable, Equatable {
        case lookUp
        case waitForSync
        case checkEarlierTries
        case create
        case save
        case waitForUpload
        case fetchLink
        case present
        case fail(Failure)
    }

    enum Event: Sendable, Equatable {
        case lookedUp(Lookup)
        case syncSettled(timedOut: Bool)
        case earlierTriesChecked(EarlierTries)
        /// `share(_:to:)`, or the call still running from an earlier try.
        case created(Outcome)
        /// `persistUpdatedShare`, with the household's name as the title.
        case saved(Outcome)
        case uploadFinished(timedOut: Bool)
        /// The share's own record, fetched from CloudKit for its link.
        case linkFetched(Outcome)
    }

    enum Lookup: Sendable, Equatable {
        /// `needsSave`: missing its title.
        case shared(hasLink: Bool, needsSave: Bool)
        /// `isSyncing`: an import or export started recently and is running.
        case notShared(isSyncing: Bool)
        /// Including a lookup that ran out of time: nobody knows whether a
        /// share exists, so nothing may make one.
        case failed(ShareCallError)
    }

    enum EarlierTries: Sendable, Equatable {
        case none
        /// Zone names, for the log; the count, for the message.
        case found([String])
        case failed(ShareCallError)
    }

    enum Outcome: Sendable, Equatable {
        case share(hasLink: Bool)
        case failed(ShareCallError)
    }

    enum Failure: Sendable, Equatable {
        case lookupFailed(ShareCallError)
        case earlierTriesLeftCopies(Int)
        case notCreated(ShareCallError?)
        case noLink(ShareCallError?)

        var title: String {
            switch self {
            case .lookupFailed: "Couldn't Check Sharing"
            case .earlierTriesLeftCopies: "An Earlier Invite Didn't Finish"
            case .notCreated: "Couldn't Create the Share"
            case .noLink: "The Link Isn't Ready"
            }
        }

        var offersShareAnyway: Bool {
            if case .earlierTriesLeftCopies = self { return true }
            return false
        }

        /// What happened, what it means for the household, and iCloud's own words.
        var message: String {
            let text: String
            switch self {
            case .lookupFailed(let error) where error.isTimeout:
                text = "iCloud didn't answer \(error.limitPhrase), so nothing was shared or changed. It's usually busy syncing; try again in a minute."
            case .lookupFailed(let error):
                text = "iCloud couldn't say whether the household is already shared, so nothing was shared or changed. \(error.saying)"
            case .earlierTriesLeftCopies(let count):
                text = "An earlier invite didn't finish: iCloud holds \(count == 1 ? "a copy" : "\(count) copies") of the household in a share this device never switched to. Nothing new was made. Share Anyway makes a fresh share; the old copy stays in iCloud, unused."
            case .notCreated(let error?) where error.isTimeout:
                text = "iCloud didn't finish making the share \(error.limitPhrase), and it hadn't arrived after the upload that followed. It may still finish on its own: Try Again opens it if it has, without making a second one."
            case .notCreated(let error):
                text = "iCloud couldn't make the share. \(error?.saying ?? "")"
            case .noLink(let error):
                text = "The share was made, but iCloud hasn't sent its link yet. Try again in a minute. \(error?.saying ?? "")"
            }
            return text.trimmingCharacters(in: .whitespaces)
        }
    }

    /// How long each step may take. A limit only ends the wait: the call
    /// itself carries on, and a later Try Again picks up what it did.
    struct Limits: Sendable, Equatable {
        var lookup: Duration = .seconds(15)
        var sync: Duration = .seconds(30)
        var earlierTries: Duration = .seconds(20)
        var create: Duration = .seconds(60)
        var save: Duration = .seconds(15)
        var upload: Duration = .seconds(40)
        var fetchLink: Duration = .seconds(15)

        static let standard = Limits()
    }

    /// Uploads waited for in one preparation: one after a failed `share()`,
    /// one more if the share then arrives without its link.
    static let maxUploadWaits = 2
    /// A sync running longer than this is stuck, not worth waiting for.
    static let longSync: TimeInterval = 5 * 60

    /// Whether a sync under way since `since` is worth waiting for before
    /// making a share: one queued behind it is what timed out in Multitrack.
    static func isWorthWaiting(forSyncSince since: Date?, asOf now: Date = .now) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) < longSync
    }

    private(set) var step: Step = .lookingUp
    /// Share Anyway: told an earlier try left copies, the person wants a
    /// fresh share regardless.
    let ignoresEarlierTries: Bool
    private(set) var didWaitForSync = false
    private(set) var didCheckEarlierTries = false
    private(set) var didCreate = false
    private(set) var uploadWaits = 0
    private var createError: ShareCallError?
    private var hasShare = false
    private var hasLink = false
    private var didSave = false

    init(ignoresEarlierTries: Bool = false) {
        self.ignoresEarlierTries = ignoresEarlierTries
    }

    /// Every preparation starts by asking whether it's shared already.
    mutating func start() -> Action {
        step = .lookingUp
        return .lookUp
    }

    mutating func handle(_ event: Event) -> Action {
        let action = decide(event)
        step = Self.step(for: action)
        return action
    }

    private mutating func decide(_ event: Event) -> Action {
        switch event {
        case .lookedUp(.shared(let link, let needsSave)):
            hasShare = true
            hasLink = link
            if needsSave && !didSave { return .save }
            return link ? .present : .fetchLink

        case .lookedUp(.notShared(let isSyncing)):
            // Already called, and after the upload iCloud has nothing:
            // calling again is what made four zones.
            if didCreate { return .fail(.notCreated(createError)) }
            if isSyncing && !didWaitForSync { return .waitForSync }
            if !ignoresEarlierTries && !didCheckEarlierTries { return .checkEarlierTries }
            return .create

        case .lookedUp(.failed(let error)):
            if didCreate { return .fail(.notCreated(createError ?? error)) }
            return .fail(.lookupFailed(error))

        case .earlierTriesChecked(let earlier):
            didCheckEarlierTries = true
            switch earlier {
            case .none: return .create
            case .found(let zones): return .fail(.earlierTriesLeftCopies(zones.count))
            case .failed(let error): return .fail(.lookupFailed(error))
            }

        case .syncSettled:
            didWaitForSync = true
            // Settled or not, look again: the import may have brought the
            // share back.
            return .lookUp

        case .created(.share(let link)):
            didCreate = true
            hasShare = true
            hasLink = link
            // Its title, before anyone is handed it.
            return .save

        case .created(.failed(let error)):
            didCreate = true
            createError = error
            // The export the call queued carries on without it.
            return .waitForUpload

        case .saved(let outcome):
            didSave = true
            if case .share(hasLink: true) = outcome { hasLink = true }
            // A missing title isn't worth withholding a share with a link.
            return hasLink ? .present : .fetchLink

        case .linkFetched(.share(hasLink: true)):
            hasLink = true
            return .present

        case .linkFetched(let outcome):
            if uploadWaits < Self.maxUploadWaits { return .waitForUpload }
            if case .failed(let error) = outcome { return .fail(.noLink(error)) }
            return .fail(.noLink(nil))

        case .uploadFinished:
            uploadWaits += 1
            // With a share in hand only its link is missing; without one,
            // ask Core Data whether the upload made it after all.
            return hasShare ? .fetchLink : .lookUp
        }
    }

    static func step(for action: Action) -> Step {
        switch action {
        case .lookUp: .lookingUp
        case .waitForSync: .waitingForSync
        case .checkEarlierTries: .checkingEarlierTries
        case .create: .creating
        case .save: .saving
        case .waitForUpload: .waitingForUpload
        case .fetchLink: .fetchingLink
        case .present: .ready
        case .fail(let failure): .failed(failure)
        }
    }
}

/// An error from a sharing call, reduced to what the sheet and the log say:
/// domain and code (for a CloudKit partial failure, the first item's code,
/// which is the real cause), CloudKit's sentence, or a timeout. Never
/// anything a person typed.
struct ShareCallError: Error, Sendable, Equatable {
    var domain: String
    var code: Int
    var underlyingCode: Int?
    var message: String
    /// Set for a step that ran out of time.
    var limit: Duration?

    var isTimeout: Bool { limit != nil }

    init(domain: String, code: Int, underlyingCode: Int? = nil, message: String) {
        self.domain = domain
        self.code = code
        self.underlyingCode = underlyingCode
        self.message = message
    }

    init(_ error: any Error) {
        let error = error as NSError
        var underlying: Int?
        if error.domain == CKError.errorDomain, error.code == CKError.partialFailure.rawValue,
           let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error] {
            // Lowest code first, so the log reads the same for the same failure.
            underlying = partial.values.map { ($0 as NSError).code }.min()
        } else if let inner = error.userInfo[NSUnderlyingErrorKey] as? NSError, inner.domain == CKError.errorDomain {
            // Core Data wraps CloudKit's error in its own.
            underlying = inner.code
        }
        self.init(domain: error.domain, code: error.code, underlyingCode: underlying, message: error.localizedDescription)
    }

    static func timedOut(after limit: Duration) -> ShareCallError {
        var error = ShareCallError(domain: "Timeout", code: 0, message: "No answer \(phrase(for: limit)).")
        error.limit = limit
        return error
    }

    /// A call that finished with neither a result nor an error.
    static let noResult = ShareCallError(domain: "Sharing", code: 0, message: "iCloud returned no share and no error.")

    /// For logs and the end of a message: "CKError 2 › 14", "Core Data 134419".
    var codeLabel: String {
        if let limit { return "timed out after \(limit.components.seconds) s" }
        let base = switch domain {
        case CKError.errorDomain: "CKError \(code)"
        case NSCocoaErrorDomain: "Core Data \(code)"
        default: "\(domain) \(code)"
        }
        return underlyingCode.map { "\(base) › CKError \($0)" } ?? base
    }

    var saying: String {
        let quote = message.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return "iCloud said: “\(quote)” (\(codeLabel))."
    }

    var limitPhrase: String { limit.map(Self.phrase(for:)) ?? "" }

    static func phrase(for limit: Duration) -> String {
        let seconds = Int(limit.components.seconds)
        if seconds >= 60, seconds % 60 == 0 {
            let minutes = seconds / 60
            return "within \(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "within \(seconds) seconds"
    }
}

/// Why a sharing call did nothing or failed. The app shows
/// `errorDescription`; `offersShareAnyway` asks for a Share Anyway button
/// (`HouseholdStore.prepareShare(ignoringEarlierTries:)`).
public enum HouseholdShareError: LocalizedError, Equatable, Sendable {
    /// No iCloud here: an in-memory store (`-InMemoryStores YES`, tests).
    case iCloudUnavailable
    /// No household has been made yet.
    case noHousehold
    /// Leaving needs a household someone else shared; this one is yours.
    case notSharedWithYou
    /// This device has no copy of the share yet: it hasn't synced down.
    case noShare
    /// Only the household's owner can do that.
    case notOwner
    /// A call finished with neither a result nor an error.
    case noResult
    /// No answer within the limit; the call may still finish on its own.
    case timedOut(String)
    /// Invite couldn't hand over a share (HH-2).
    case preparationFailed(title: String, message: String, offersShareAnyway: Bool)
    /// iCloud refused, in its own words.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .iCloudUnavailable: "iCloud isn't in use on this device, so the household can't be shared from here."
        case .noHousehold: "The household hasn't been set up yet."
        case .notSharedWithYou: "This household is yours, so there's nothing to leave."
        case .noShare: "iCloud hasn't finished downloading this household's share yet. Try again in a minute."
        case .notOwner: "Only the household's owner can do that."
        case .noResult: "iCloud returned no answer and no error."
        case .timedOut(let what): "iCloud didn't answer in time (\(what)). It may still finish; try again in a minute."
        case .preparationFailed(_, let message, _): message
        case .failed(let message): message
        }
    }

    /// The sheet's title for a failed Invite.
    public var title: String {
        switch self {
        case .preparationFailed(let title, _, _): title
        case .notSharedWithYou, .noShare: "Couldn't Leave"
        default: "iCloud Sharing"
        }
    }

    public var offersShareAnyway: Bool {
        if case .preparationFailed(_, _, true) = self { return true }
        return false
    }

    init(_ failure: HouseholdSharePlan.Failure) {
        self = .preparationFailed(title: failure.title, message: failure.message, offersShareAnyway: failure.offersShareAnyway)
    }
}
