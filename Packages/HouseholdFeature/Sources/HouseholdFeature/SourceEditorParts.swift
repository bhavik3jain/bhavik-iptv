import CatalogKit
import Core
import HouseholdKit
import SourceKit
import SwiftUI

/// One field of the source editor: a small caption above the text, so the
/// field still says what it is once filled (iOS forms show only a
/// placeholder), and a line under it when what was typed can't work.
struct SourceField: View {
    enum Style {
        /// Ordinary text with the system's capitalisation.
        case plain
        /// A web address: URL keyboard, no autocorrection.
        case url
        /// Exact text in mono: MAC addresses, ids, usernames.
        case code
        /// A password: masked, never shown back.
        case secure
    }

    let title: String
    @Binding var text: String
    let prompt: String
    var style: Style = .plain
    var problem: String?
    /// A green tick: the MAC address is complete and well formed.
    var isConfirmed = false

    init(_ title: String, text: Binding<String>, prompt: String, style: Style = .plain, problem: String? = nil, isConfirmed: Bool = false) {
        self.title = title
        self._text = text
        self.prompt = prompt
        self.style = style
        self.problem = problem
        self.isConfirmed = isConfirmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.hearthCaption)
                .foregroundStyle(HearthColor.textSecondary)
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                field
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .font(style == .code ? .hearthMono(15, relativeTo: .body) : .hearthBody)
                    .foregroundStyle(HearthColor.textPrimary)
                    .frame(minHeight: 32)
                    .accessibilityHint(problem.map { Text($0) } ?? Text(""))
                if isConfirmed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(HearthColor.success)
                        .accessibilityLabel(Text("Looks right"))
                }
            }
            if let problem {
                Text(problem)
                    .font(.hearthCaption)
                    .foregroundStyle(HearthColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var field: some View {
        switch style {
        case .secure:
            SecureField(title, text: $text, prompt: Text(prompt))
                .textContentType(.password)
        case .url:
            TextField(title, text: $text, prompt: Text(prompt))
                .urlEntryKeyboard()
                .textContentType(.URL)
        case .code:
            TextField(title, text: $text, prompt: Text(prompt))
                .noAutocapitalization()
        case .plain:
            TextField(title, text: $text, prompt: Text(prompt))
        }
    }
}

/// What "Test connection" found (SRC-4): signed in with counts and the
/// account's expiry, or the provider's own message, with every step and its
/// timing (logins already masked by SourceKit) for when it fails.
struct SourceTestResultCard: View {
    let result: SourceTestResult
    let kind: SourceKind
    @State private var showsSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(result.succeeded ? String(localized: "Signed in") : String(localized: "Couldn't sign in"))
                    .font(.hearthHeadline)
                    .foregroundStyle(HearthColor.textPrimary)
            } icon: {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.succeeded ? HearthColor.success : HearthColor.danger)
            }
            if result.succeeded, let counts = HouseholdFormat.counts(channels: result.channelCount, movies: result.movieCount, series: result.seriesCount) {
                Text(counts)
                    .font(.hearthBody)
                    .foregroundStyle(HearthColor.textPrimary)
            }
            ForEach(TestResultText.accountLines(result.account, kind: kind), id: \.self) { line in
                Text(line.text)
                    .font(.hearthFootnote)
                    .foregroundStyle(line.isWarning ? HearthColor.danger : HearthColor.textSecondary)
            }
            if let message = result.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                // The provider's own words, as they are (SRC-4).
                Text(message)
                    .font(.hearthCallout)
                    .foregroundStyle(result.succeeded ? HearthColor.textSecondary : HearthColor.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !result.steps.isEmpty {
                DisclosureGroup(isExpanded: $showsSteps) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(result.steps.enumerated()), id: \.offset) { _, step in
                            Text(step)
                                .font(.hearthMono(12, relativeTo: .caption))
                                .foregroundStyle(HearthColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.top, 4)
                } label: {
                    Text(result.succeeded ? String(localized: "Steps") : String(localized: "What happened"))
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textSecondary)
                        .frame(minHeight: HearthMetrics.minimumHitTarget)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

/// The account lines under a test result: expiry, trial, Xtream's limit.
enum TestResultText {
    struct Line: Hashable {
        var text: String
        var isWarning = false
    }

    static func accountLines(_ account: AccountInfo?, kind: SourceKind, now: Date = .now) -> [Line] {
        guard let account else { return [] }
        var lines: [Line] = []
        switch account.status {
        case .expired:
            if let date = account.expiresAt {
                lines.append(Line(text: String(localized: "Expired on \(HouseholdFormat.day(date))"), isWarning: true))
            } else {
                lines.append(Line(text: String(localized: "The provider says this login has expired."), isWarning: true))
            }
        case .disabled:
            lines.append(Line(text: String(localized: "The provider has disabled this login."), isWarning: true))
        case .active, .unknown:
            if let date = account.expiresAt {
                if date < now {
                    lines.append(Line(text: String(localized: "Expired on \(HouseholdFormat.day(date))"), isWarning: true))
                } else {
                    lines.append(Line(text: String(localized: "Active until \(HouseholdFormat.day(date))")))
                }
            } else if account.status == .active {
                lines.append(Line(text: String(localized: "Active, no end date given")))
            }
        }
        if account.isTrial {
            lines.append(Line(text: String(localized: "A trial login")))
        }
        if kind == .xtream, let max = account.maxConnections, max > 0 {
            let line = max == 1 ? String(localized: "1 stream allowed at once") : String(localized: "\(max) streams allowed at once")
            if let active = account.activeConnections {
                lines.append(Line(text: line + " · " + String(localized: "\(active) in use now")))
            } else {
                lines.append(Line(text: line))
            }
        }
        return lines
    }
}

/// The top of the editor for a saved source (SRC-5, SRC-6): whether it is
/// active and until when, what this device last downloaded and when, the
/// last failure in the provider's words, and Refresh Now (or Stop while it
/// runs).
struct SourceStatusSection: View {
    let record: SourceRecord
    @Environment(CatalogService.self) private var catalog

    var body: some View {
        let text = SourceStatusText(record: record, state: catalog.refreshStates[record.id])
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if text.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(HearthColor.textSecondary)
                    } else {
                        Image(systemName: text.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(text.isWarning ? HearthColor.danger : HearthColor.success)
                            .accessibilityHidden(true)
                    }
                    Text(text.headline)
                        .font(.hearthHeadline)
                        .foregroundStyle(HearthColor.textPrimary)
                }
                if let detail = text.detail {
                    Text(detail)
                        .font(.hearthBody)
                        .foregroundStyle(HearthColor.textPrimary)
                }
                if let updated = text.updated {
                    Text(updated)
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textSecondary)
                }
                if let failure = text.failure {
                    // The provider's own words (SRC-4), already free of logins.
                    Text(failure)
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            Group {
                if text.isRefreshing {
                    Button(String(localized: "Stop Updating"), systemImage: "stop.circle") {
                        catalog.cancelRefresh(sourceID: record.id)
                    }
                    .accessibilityHint(Text("Keeps what this device downloaded before"))
                } else {
                    Button(String(localized: "Refresh Now"), systemImage: "arrow.clockwise") {
                        SourceRefresher.refresh([record.id], in: catalog)
                    }
                    .accessibilityHint(Text("Downloads this source's channels, movies and guide again on this device"))
                }
            }
            .foregroundStyle(HearthColor.accent)
            .frame(minHeight: HearthMetrics.minimumHitTarget)
        } header: {
            SectionLabel(String(localized: "Status"), style: .card)
        } footer: {
            Text("Refresh Now uses the login as saved. Channel lists, posters and the guide download on each device.")
                .font(.hearthFootnote)
                .foregroundStyle(HearthColor.textSecondary)
        }
        .listRowBackground(HearthColor.surface)
    }
}
