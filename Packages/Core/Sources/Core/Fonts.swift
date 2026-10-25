import CoreText
import Foundation

/// Registers every .ttf/.otf in Core's `Resources/Fonts` with Core Text for
/// this process, once.
///
/// Registration runs inside a `static let` initialiser: Swift runs those
/// exactly once, lazily and thread-safely, so the first `Font.hearth…` call on
/// any thread pays for it and every later call is a plain read, with no lock
/// and no mutable global state.
enum HearthFontRegistration {
    /// PostScript names of every face that is registered for this process,
    /// whether by this call or (in a test host or a second bundle copy)
    /// already.
    static let registeredPostScriptNames: Set<String> = registerBundledFonts()

    static func ensureRegistered() {
        _ = registeredPostScriptNames
    }

    /// The bundled font files. `.process` resources may be flattened into the
    /// bundle root or kept under `Fonts/` depending on the build system
    /// (SwiftPM vs Xcode), so both places are searched.
    static func bundledFontURLs() -> [URL] {
        let urls = ["ttf", "otf"].flatMap {
            (Bundle.module.urls(forResourcesWithExtension: $0, subdirectory: "Fonts") ?? [])
                + (Bundle.module.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [])
        }
        // Deduplicate by file name: the same face found in two places is
        // registered once.
        var seen = Set<String>()
        return urls.filter { seen.insert($0.lastPathComponent).inserted }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func registerBundledFonts() -> Set<String> {
        var names = Set<String>()
        for url in bundledFontURLs() {
            let descriptors = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
            let postScriptNames = descriptors.compactMap {
                CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String
            }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                names.formUnion(postScriptNames)
            } else if let error = error?.takeRetainedValue(),
                      CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue {
                names.formUnion(postScriptNames)
            }
        }
        return names
    }
}
