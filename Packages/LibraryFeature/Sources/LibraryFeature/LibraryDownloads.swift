import CatalogKit
import Core
import DownloadKit
import SwiftUI

// Downloads (DL-1) from the library: the button on a movie's page and on
// each episode row, and what each state of a download offers. The app starts
// them (`\.download`: stream limit, fresh link); DownloadKit keeps them.

/// What the download button shows and does for one item.
enum DownloadControl: Equatable {
    case start
    case running(fraction: Double)
    case paused
    case retry
    case downloaded

    init(_ record: DownloadRecord?) {
        switch record?.state {
        case nil: self = .start
        case .running: self = .running(fraction: record?.fraction ?? 0)
        case .paused: self = .paused
        case .failed: self = .retry
        case .finished: self = .downloaded
        }
    }

    var systemImage: String {
        switch self {
        case .start: "arrow.down.circle"
        case .running: "pause.fill"
        case .paused: "arrow.down.circle"
        case .retry: "exclamationmark.arrow.circlepath"
        case .downloaded: "checkmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .start: String(localized: "Download", bundle: .module)
        case .running(let fraction): String(localized: "Downloading, \(Int((fraction * 100).rounded())) percent. Pause", bundle: .module)
        case .paused: String(localized: "Resume download", bundle: .module)
        case .retry: String(localized: "Try the download again", bundle: .module)
        case .downloaded: String(localized: "Downloaded. Remove download", bundle: .module)
        }
    }
}

/// The download button's behaviour, shared by its two sizes.
private struct DownloadControlModifier: ViewModifier {
    let request: DownloadRequest
    @Binding var isConfirmingRemove: Bool

    @Environment(DownloadCenter.self) private var downloads

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                String(localized: "Remove this download?", bundle: .module),
                isPresented: $isConfirmingRemove,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Remove Download", bundle: .module), role: .destructive) {
                    downloads.remove(request.itemKey)
                }
                Button(String(localized: "Keep It", bundle: .module), role: .cancel) {}
            } message: {
                Text("It goes from this device only; you can download it again.", bundle: .module)
            }
    }
}

/// Runs the control's action.
@MainActor
private func perform(_ control: DownloadControl, request: DownloadRequest, downloads: DownloadCenter, download: DownloadAction, confirmRemove: () -> Void) {
    switch control {
    case .start, .retry:
        download(request)
    case .running:
        downloads.pause(request.itemKey)
    case .paused:
        // A task lost in a relaunch starts again from a fresh link.
        if !downloads.resume(request.itemKey) { download(request) }
    case .downloaded:
        confirmRemove()
    }
}

/// The 48-pt square beside a movie's Play button (mockup 04's download
/// button). Hidden where downloads aren't offered (the Apple TV).
struct DownloadSquareButton: View {
    let request: DownloadRequest

    @Environment(DownloadCenter.self) private var downloads
    @Environment(\.download) private var download
    @State private var isConfirmingRemove = false

    var body: some View {
        if DownloadCenter.isSupported {
            let control = DownloadControl(downloads.record(for: request.itemKey))
            Button {
                perform(control, request: request, downloads: downloads, download: download) { isConfirmingRemove = true }
            } label: {
                DownloadGlyph(control: control, size: 19)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HearthColor.surfaceButton))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.hearthTile)
            .accessibilityLabel(Text(control.label))
            .modifier(DownloadControlModifier(request: request, isConfirmingRemove: $isConfirmingRemove))
        }
    }
}

/// The icon-sized download button at the end of an episode row.
struct DownloadIconButton: View {
    let request: DownloadRequest

    @Environment(DownloadCenter.self) private var downloads
    @Environment(\.download) private var download
    @State private var isConfirmingRemove = false

    var body: some View {
        if DownloadCenter.isSupported {
            let control = DownloadControl(downloads.record(for: request.itemKey))
            Button {
                perform(control, request: request, downloads: downloads, download: download) { isConfirmingRemove = true }
            } label: {
                DownloadGlyph(control: control, size: 17)
                    .frame(width: HearthMetrics.minimumHitTarget, height: HearthMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(control.label))
            .modifier(DownloadControlModifier(request: request, isConfirmingRemove: $isConfirmingRemove))
        }
    }
}

/// The symbol, with a progress ring round it while it downloads.
struct DownloadGlyph: View {
    let control: DownloadControl
    let size: CGFloat

    var body: some View {
        ZStack {
            if case .running(let fraction) = control {
                Circle()
                    .stroke(HearthColor.textTertiary.opacity(0.35), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(HearthColor.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: fraction)
                Image(systemName: control.systemImage)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(HearthColor.accent)
            } else {
                Image(systemName: control.systemImage)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(control == .downloaded ? HearthColor.accent : (control == .retry ? HearthColor.danger : HearthColor.textPrimary))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: size * 1.45, height: size * 1.45)
    }
}

extension DownloadRequest {
    init(movie: CatalogMovie) {
        self.init(
            itemKey: movie.key.rawValue,
            kind: .movie,
            title: movie.name,
            subtitle: movie.year.map(String.init),
            artworkURL: movie.posterURL,
            sourceID: movie.sourceID
        )
    }

    init(episode: CatalogEpisode, series: CatalogSeries) {
        self.init(
            itemKey: episode.key.rawValue,
            kind: .episode,
            title: series.name,
            subtitle: episode.playerSubtitle,
            artworkURL: episode.posterURL ?? series.posterURL,
            sourceID: episode.sourceID,
            seriesKey: series.key.rawValue
        )
    }
}

/// "1.2 GB", "340 MB".
enum DownloadFormat {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The line under a download's title.
    static func status(_ record: DownloadRecord) -> String {
        switch record.state {
        case .running:
            let percent = Int((record.fraction * 100).rounded())
            if let expected = record.bytesExpected {
                return String(localized: "Downloading · \(percent)% of \(size(expected))", bundle: .module)
            }
            return String(localized: "Downloading · \(percent)%", bundle: .module)
        case .paused:
            return String(localized: "Paused · \(Int((record.fraction * 100).rounded()))%", bundle: .module)
        case .failed:
            return record.failureMessage.map { String(localized: "Couldn't download: \($0)", bundle: .module) }
                ?? String(localized: "Couldn't download", bundle: .module)
        case .finished:
            return record.bytesWritten > 0 ? size(record.bytesWritten) : String(localized: "Downloaded", bundle: .module)
        }
    }
}
