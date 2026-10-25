import Foundation

/// `-SourceProbe <name>`: walks a real source through the calls a refresh and
/// a play make, printing each step with its timing, so the "unverified"
/// protocol rows can be checked against the owner's provider (Source
/// protocols, Verification checklist; SRC-4).
///
/// Every line that leaves here is masked: the configuration is printed
/// `redacted`, provider text is scrubbed of the MAC and logins, and links
/// keep only their scheme and host (PRIV-2). Stream URLs carry tokens and,
/// for Xtream, the password.
public enum SourceProbe {
    public static func run(_ configuration: SourceConfiguration, session: URLSession = .shared, log: @Sendable (String) -> Void) async {
        let client = SourceClientFactory.make(configuration, session: session)
        await run(client: client, log: log)
    }

    /// The probe over any client (tests hand it the stub).
    static func run(client: any SourceClient, log: @Sendable (String) -> Void) async {
        let configuration = client.configuration
        let safe = configuration.redacted
        func say(_ line: String) { log(Redaction.scrub(line, for: configuration)) }
        say("Probe: \(safe.name) (\(safe.kind.rawValue)) server \(Redaction.url(safe.serverURL)) MAC \(safe.macAddress)")
        if !safe.playlistURL.isEmpty { say("  playlist \(safe.playlistURL)") }
        let started = ContinuousClock.now

        guard let account = await step("Sign in", say: say, { try await client.signIn() }) else {
            say("Stopped: sign-in failed.")
            return
        }
        say("  status \(account.status.rawValue)\(account.expiresAt.map { ", expires \(Self.format($0))" } ?? "")"
            + "\(account.maxConnections.map { ", streams \(account.activeConnections ?? 0)/\($0)" } ?? "")"
            + (account.allowedOutputFormats.isEmpty ? "" : ", formats \(account.allowedOutputFormats.joined(separator: ","))")
            + (account.message.map { " — “\($0)”" } ?? ""))

        if let refreshed = await step("Account", say: say, { try await client.accountInfo() }) {
            say("  status \(refreshed.status.rawValue)\(refreshed.expiresAt.map { ", expires \(Self.format($0))" } ?? ", no expiry given")")
        }

        for kind in ContentKind.allCases {
            if kind == .vod, !client.capabilities.hasMovies { continue }
            if kind == .series, !client.capabilities.hasSeries { continue }
            if let categories = await step("Categories (\(kind.rawValue))", say: say, { try await client.categories(kind) }) {
                say("  \(categories.count) categories" + (categories.isEmpty ? "" : ": " + categories.prefix(6).map(\.name).joined(separator: ", ") + (categories.count > 6 ? ", …" : "")))
            }
        }

        let channels = await step("Channels", say: say, { try await client.channels() }) ?? []
        if !channels.isEmpty {
            let archived = channels.filter(\.hasArchive).count
            let formats = Dictionary(grouping: channels, by: \.formatHint).map { "\($0.key.rawValue) \($0.value.count)" }.sorted().joined(separator: ", ")
            say("  \(channels.count) channels, \(archived) with archive; formats \(formats)")
        }

        if client.capabilities.hasMovies, let page = await step("Movies (page 0)", say: say, { try await client.movies(categoryID: nil, page: 0) }) {
            say("  \(page.items.count) on the page\(page.totalItems.map { " of \($0)" } ?? "")\(page.hasMore ? ", more follow" : "")")
        }
        if client.capabilities.hasSeries, let page = await step("Series (page 0)", say: say, { try await client.series(categoryID: nil, page: 0) }) {
            say("  \(page.items.count) on the page\(page.totalItems.map { " of \($0)" } ?? "")")
        }

        if let channel = channels.first {
            say("  using channel \(channel.number.map(String.init) ?? "—") \(channel.name)")
            if let link = await step("Live link", say: say, { try await client.streamLink(for: .live(channel)) }) {
                say("  \(Redaction.url(link.url.absoluteString)) as \(link.formatHint.rawValue)\(link.headers.isEmpty ? "" : ", headers \(link.headers.keys.sorted().joined(separator: ","))")")
            }
            if let guide = await step("Short guide", say: say, { try await client.shortGuide(for: channel, limit: 4) }) {
                say("  \(guide.count) programmes" + (guide.first.map { ", first “\($0.title)” \(Self.format($0.start))–\(Self.format($0.end))" } ?? ""))
            }
        }

        say("Done in \(Self.milliseconds(ContinuousClock.now - started)) ms.")
    }

    /// Runs one step, printing its outcome and timing; nil when it failed.
    private static func step<T: Sendable>(_ name: String, say: (String) -> Void, _ work: () async throws -> T) async -> T? {
        let started = ContinuousClock.now
        do {
            let value = try await work()
            say("✓ \(name) — \(milliseconds(ContinuousClock.now - started)) ms")
            return value
        } catch let error as SourceError {
            var line = "✗ \(name) — \(milliseconds(ContinuousClock.now - started)) ms — \(error.code.rawValue)"
            if let message = error.providerMessage { line += " — provider says “\(message)”" }
            if let detail = error.detail { line += " (\(detail))" }
            say(line)
            return nil
        } catch {
            say("✗ \(name) — \(milliseconds(ContinuousClock.now - started)) ms — \(type(of: error))")
            return nil
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func format(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.colon).dateTimeSeparator(.space))
    }
}
