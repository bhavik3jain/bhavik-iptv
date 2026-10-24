import Foundation

/// "1 stream", "2 streams": the count and the right noun, for the handful of
/// places a string catalog's plural rule would be overkill.
public func counted(_ count: Int, _ singular: String, plural: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
}
