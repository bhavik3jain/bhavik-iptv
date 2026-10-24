import Core
import SwiftUI

// PLACEHOLDER — replaced by the app shell (see docs/TRACKING.md).
@main
struct HearthApp: App {
    init() {
        HearthFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            Text("Hearth")
                .font(.hearthDisplay(40))
                .foregroundStyle(HearthColor.textPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .hearthScreenBackground()
        }
    }
}
