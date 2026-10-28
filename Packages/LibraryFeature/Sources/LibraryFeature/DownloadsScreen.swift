import Core
import DownloadKit
import SwiftUI

/// Movies and episodes saved on this device (DL-1): the ones still coming,
/// then the ones ready to watch offline, with what they take on disk. A
/// finished one plays from its file; the rest pause, resume or try again.
struct DownloadsScreen: View {
    @Environment(DownloadCenter.self) private var downloads
    @Environment(\.hearthLayout) private var layout

    private var inProgress: [DownloadRecord] { downloads.records.filter { $0.state != .finished } }
    private var finished: [DownloadRecord] { downloads.records.filter { $0.state == .finished } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LibraryTitleRow(title: String(localized: "Downloads", bundle: .module)) { EmptyView() }
                    .padding(.top, 4)
                if !DownloadCenter.isSupported {
                    empty(
                        title: String(localized: "Downloads aren't on Apple TV", bundle: .module),
                        message: String(localized: "Download movies and episodes on your iPhone, iPad or Mac to watch them offline there.", bundle: .module)
                    )
                } else if downloads.records.isEmpty {
                    empty(
                        title: String(localized: "No downloads yet", bundle: .module),
                        message: String(localized: "Tap the download button on a movie or an episode to watch it offline. Downloads stay on this device, and take one of the provider's streams while they run.", bundle: .module)
                    )
                } else {
                    if !inProgress.isEmpty {
                        section(String(localized: "Downloading", bundle: .module), inProgress)
                    }
                    if !finished.isEmpty {
                        section(String(localized: "On this device", bundle: .module), finished)
                        Text("\(DownloadFormat.size(downloads.bytesOnDisk)) on this device", bundle: .module)
                            .font(.hearthFootnote)
                            .foregroundStyle(HearthColor.textSecondary)
                    }
                }
            }
            .padding(.horizontal, libraryGutter(layout))
            .padding(.bottom, 32)
            .frame(maxWidth: libraryMaxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollRevealedTitle(String(localized: "Downloads", bundle: .module))
        .hearthScreenBackground()
    }

    private func empty(title: String, message: String) -> some View {
        EmptyStateView(systemName: "arrow.down.circle", title: title, message: message)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
    }

    private func section(_ title: String, _ records: [DownloadRecord]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.hearthHeadline)
                .foregroundStyle(HearthColor.textPrimary)
                .padding(.bottom, 6)
            ForEach(records) { record in
                DownloadRowView(record: record)
                if record.id != records.last?.id {
                    Rectangle()
                        .fill(HearthColor.hairline)
                        .frame(height: 1)
                        .padding(.leading, 74)
                }
            }
        }
    }
}

/// One download: its artwork, title and where it stands; a finished one
/// plays when tapped, the rest have their control at the end.
private struct DownloadRowView: View {
    let record: DownloadRecord

    @Environment(DownloadCenter.self) private var downloads
    @Environment(\.play) private var play
    @State private var isConfirmingRemove = false

    private var request: DownloadRequest {
        DownloadRequest(itemKey: record.id, kind: record.kind, title: record.title, subtitle: record.subtitle,
                        artworkURL: record.artworkURL, sourceID: record.sourceID, seriesKey: record.seriesKey)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                guard record.state == .finished else { return }
                play(PlayIntent(
                    itemKey: record.id,
                    kind: record.kind == .movie ? .movie : .episode,
                    title: record.title,
                    subtitle: record.subtitle,
                    artworkURL: record.artworkURL
                ))
            } label: {
                HStack(spacing: 14) {
                    ArtworkView(url: record.artworkURL, title: record.title)
                        .frame(width: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.title)
                            .font(.hearthBody.weight(.semibold))
                            .foregroundStyle(HearthColor.textPrimary)
                            .lineLimit(2)
                        if let subtitle = record.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.hearthCallout)
                                .foregroundStyle(HearthColor.textSecondary)
                                .lineLimit(1)
                        }
                        Text(DownloadFormat.status(record))
                            .font(.hearthFootnote)
                            .foregroundStyle(record.state == .failed ? HearthColor.danger : HearthColor.textTertiary)
                            .lineLimit(2)
                        if record.state == .running || record.state == .paused {
                            HearthProgressBar(value: record.fraction, height: 4)
                                .frame(maxWidth: 220)
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hearthTile)
            .accessibilityHint(record.state == .finished ? Text("Plays it from this device", bundle: .module) : Text(""))

            DownloadIconButton(request: request)
        }
        .contextMenu {
            if record.state == .running {
                Button {
                    downloads.pause(record.id)
                } label: {
                    Label(String(localized: "Pause", bundle: .module), systemImage: "pause")
                }
            }
            Button(role: .destructive) {
                isConfirmingRemove = true
            } label: {
                Label(record.state == .finished ? String(localized: "Remove Download", bundle: .module) : String(localized: "Cancel Download", bundle: .module), systemImage: "trash")
            }
        }
        .confirmationDialog(
            record.state == .finished ? String(localized: "Remove this download?", bundle: .module) : String(localized: "Cancel this download?", bundle: .module),
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button(record.state == .finished ? String(localized: "Remove Download", bundle: .module) : String(localized: "Cancel Download", bundle: .module), role: .destructive) {
                downloads.remove(record.id)
            }
            Button(String(localized: "Keep It", bundle: .module), role: .cancel) {}
        }
    }
}
