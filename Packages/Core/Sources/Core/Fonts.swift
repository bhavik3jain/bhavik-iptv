import CoreText
import Foundation

/// Registers every .ttf/.otf in Core's `Resources/Fonts` for this process.
enum HearthFontRegistration {
    nonisolated(unsafe) private static var registered = false
    private static let lock = NSLock()

    static func registerBundledFonts() {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return }
        registered = true
        let urls = ["ttf", "otf"].flatMap {
            Bundle.module.urls(forResourcesWithExtension: $0, subdirectory: "Fonts") ?? []
        } + ["ttf", "otf"].flatMap {
            Bundle.module.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? []
        }
        for url in Set(urls) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
