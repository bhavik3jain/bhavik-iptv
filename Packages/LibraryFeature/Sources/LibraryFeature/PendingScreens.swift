import CatalogKit
import Core
import SwiftUI

// Temporary: replaced screen by screen.

struct MyListScreen: View {
    var body: some View { Text("My List").hearthScreenBackground() }
}

struct MovieDetailScreen: View {
    let itemKey: ItemKey
    var body: some View { Text("Movie").hearthScreenBackground() }
}

struct ShowDetailScreen: View {
    let itemKey: ItemKey
    var body: some View { Text("Show").hearthScreenBackground() }
}
