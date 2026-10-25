import Core
import SwiftUI

public struct SourceEditorView: View {
    let sourceID: UUID?
    public init(sourceID: UUID?) { self.sourceID = sourceID }
    public var body: some View {
        Text("Source editor").hearthScreenBackground()
    }
}
