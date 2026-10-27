import Core
import SwiftUI

/// Settings › Acknowledgements: one card per thing Hearth uses, at a readable
/// width. VLCKit's card carries what the LGPL asks for — that it is there,
/// the licence, the user's right to replace it and the written source offer
/// (technical spec: VLCKit) — and the fonts card the OFL notices with the full
/// licence text a tap away.
struct AcknowledgementsScreen: View {
    @Environment(\.hearthLayout) private var layout
    @State private var showsFontLicense = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HearthMetrics.sectionSpacing) {
                Text("Hearth is built with open-source software and fonts. Thank you to the people who make them.", bundle: .module)
                    .font(.hearthBody)
                    .foregroundStyle(HearthColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                vlcKitCard
                fontsCard
                appleSamplesCard
            }
            .padding(.horizontal, layout == .sidebar ? 32 : 20)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .hearthScreenBackground()
        .navigationTitle(Text("Acknowledgements", bundle: .module))
        .inlineNavigationTitle()
    }

    // MARK: VLCKit

    private var vlcKitCard: some View {
        AcknowledgementCard(
            title: Acknowledgements.vlcKitName,
            meta: "\(Acknowledgements.vlcKitVersion) · LGPL-2.1-or-later · VideoLAN"
        ) {
            BodyText(Acknowledgements.vlcKitNotice)
            BodyText(Acknowledgements.vlcKitSourceOffer)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: Acknowledgements.vlcKitSourceURL.absoluteString)
                Text(verbatim: Acknowledgements.vlcSourceURL.absoluteString)
            }
            .font(.hearthMono(12, relativeTo: .caption))
            .foregroundStyle(HearthColor.textTertiary)
            .hearthTextSelectable()
            VStack(alignment: .leading, spacing: 0) {
                CardLink(String(localized: "VLCKit source code", bundle: .module), systemImage: "chevron.left.forwardslash.chevron.right", url: Acknowledgements.vlcKitSourceURL)
                CardLink(String(localized: "libVLC source code", bundle: .module), systemImage: "chevron.left.forwardslash.chevron.right", url: Acknowledgements.vlcSourceURL)
                CardLink(String(localized: "GNU LGPL 2.1 licence text", bundle: .module), systemImage: "doc.text", url: Acknowledgements.vlcKitLicenseURL)
            }
        }
    }

    // MARK: Fonts

    private var fontsCard: some View {
        AcknowledgementCard(
            title: String(localized: "Fonts", bundle: .module),
            meta: Acknowledgements.fontLicenseName
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Acknowledgements.fonts) { font in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: font.name)
                                .font(.hearthText(15, weight: .medium, relativeTo: .body))
                                .foregroundStyle(HearthColor.textPrimary)
                            Text(font.role)
                                .font(.hearthCaption)
                                .foregroundStyle(HearthColor.textTertiary)
                        }
                        Text(verbatim: font.copyright)
                            .font(.hearthFootnote)
                            .foregroundStyle(HearthColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Link(destination: font.projectURL) {
                            Text(verbatim: font.projectURL.absoluteString)
                                .font(.hearthMono(12, relativeTo: .caption))
                                .foregroundStyle(HearthColor.accent)
                                .frame(minHeight: HearthMetrics.minimumHitTarget, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text("\(font.name) project page", bundle: .module))
                    }
                }
            }
            BodyText(String(localized: "Bundled unmodified under the SIL Open Font License, Version 1.1.", bundle: .module))
            if let text = Acknowledgements.fontLicenseText() {
                HearthDisclosureGroup(isExpanded: $showsFontLicense) {
                    Text(verbatim: text)
                        .font(.hearthMono(11, relativeTo: .caption2))
                        .foregroundStyle(HearthColor.textSecondary)
                        .hearthTextSelectable()
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                } label: {
                    Text("Full licence text", bundle: .module)
                        .font(.hearthText(15, weight: .medium, relativeTo: .body))
                        .foregroundStyle(HearthColor.accent)
                        .frame(minHeight: HearthMetrics.minimumHitTarget, alignment: .leading)
                }
                .tint(HearthColor.accent)
            } else {
                CardLink(String(localized: "SIL Open Font License 1.1", bundle: .module), systemImage: "doc.text", url: Acknowledgements.fontLicenseURL)
            }
        }
    }

    // MARK: Apple's samples

    private var appleSamplesCard: some View {
        AcknowledgementCard(
            title: String(localized: "Apple HLS examples", bundle: .module),
            meta: String(localized: "Development builds only", bundle: .module)
        ) {
            BodyText(Acknowledgements.appleSamplesNotice)
            CardLink(String(localized: "HTTP Live Streaming examples", bundle: .module), systemImage: "safari", url: Acknowledgements.appleSamplesURL)
        }
    }
}

// MARK: - Pieces

private struct AcknowledgementCard<Content: View>: View {
    let title: String
    let meta: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.hearthHeadline)
                    .foregroundStyle(HearthColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: meta)
                    .font(.hearthMono(12, relativeTo: .caption))
                    .foregroundStyle(HearthColor.accent)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hearthCard(padding: 20)
    }
}

private struct BodyText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.hearthCallout)
            .foregroundStyle(HearthColor.textSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An amber link row, 44 pt tall, opening in the browser.
private struct CardLink: View {
    let title: String
    let systemImage: String
    let url: URL

    init(_ title: String, systemImage: String, url: URL) {
        self.title = title
        self.systemImage = systemImage
        self.url = url
    }

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.hearthText(15, weight: .medium, relativeTo: .body))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HearthColor.glyphMuted)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(HearthColor.accent)
            .frame(minHeight: HearthMetrics.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens in your browser", bundle: .module))
    }
}
