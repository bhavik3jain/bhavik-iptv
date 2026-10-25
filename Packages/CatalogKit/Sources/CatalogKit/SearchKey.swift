import Foundation

/// The normalised form of a name that search, channel lookup and stable-key
/// replacement all compare (SRCH-1, LIV-6, FAV-2). Stored on every channel,
/// programme, movie and show as `searchKey`, so a query is a plain `CONTAINS`
/// on an already-folded column instead of a `[cd]` comparison per row, which
/// is what keeps 50,000 movies searchable as you type.
///
/// The rules: case and diacritics folded ("Café" → "cafe"), apostrophes and
/// dots dropped so "Grey's" and "S.W.A.T." read as "greys" and "swat", every
/// other run of punctuation, symbols or whitespace collapsed to one space.
/// Letters and digits of every script are kept.
public enum SearchKey {
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if dropped.contains(scalar) { continue }
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return String(result)
    }

    /// The words of a query, each matched with `CONTAINS`.
    public static func tokens(_ query: String) -> [String] {
        normalize(query).split(separator: " ").map(String.init)
    }

    /// Characters that vanish rather than split a word.
    private static let dropped: Set<Unicode.Scalar> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}", "`", "."]
}

/// The name match behind "adult categories hidden by default" (PAR-1). The
/// household can mark more (`CatalogFilter.adultCategoryIDs`); this only
/// catches the categories providers label themselves.
public enum AdultContent {
    /// Matched anywhere in the folded name: providers write "XXX", "Adult
    /// 18+", "+18 Movies", "FOR ADULTS". "+18" is the same label written the
    /// other way round, common on European portals.
    static let markers = ["adult", "xxx", "18+", "+18", "porn"]

    public static func matches(_ categoryName: String) -> Bool {
        let folded = categoryName.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        return markers.contains { folded.contains($0) }
    }
}
