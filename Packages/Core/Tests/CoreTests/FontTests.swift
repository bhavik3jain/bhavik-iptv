import CoreText
import SwiftUI
import Testing
@testable import Core

/// The bundled typefaces must be found by Core Text under the exact names
/// `Font.hearth…` asks for, or every screen silently falls back to the
/// system font.
@Suite struct FontTests {
    init() {
        HearthFonts.register()
    }

    @Test func everyBundledFaceIsRegistered() {
        for face in HearthFontFace.allCases {
            #expect(HearthFonts.isRegistered(face), "\(face.postScriptName) was not found in Core's bundle")
        }
    }

    /// `CTFontCreateWithName` never fails: an unknown name quietly returns a
    /// fallback (Helvetica or Times), so the test compares the names of the
    /// font it gets back.
    @Test(arguments: HearthFontFace.allCases)
    func coreTextFindsTheFaceByPostScriptName(_ face: HearthFontFace) {
        let font = CTFontCreateWithName(face.postScriptName as CFString, 17, nil)
        #expect(CTFontCopyPostScriptName(font) as String == face.postScriptName)
        #expect(CTFontCopyFamilyName(font) as String == face.family.familyName)
    }

    @Test(arguments: HearthFontFamily.allCases)
    func coreTextFindsEachFamily(_ family: HearthFontFamily) {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family.familyName] as CFDictionary)
        let matches = (CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor]) ?? []
        let names = Set(matches.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String })
        #expect(names.isSuperset(of: family.faces.map(\.postScriptName)), "\(family.familyName) has \(names.sorted())")
    }

    /// The faces' own weight tables agree with the CSS weights the mockups
    /// use, so asking for `.semibold` really draws a semibold.
    @Test(arguments: HearthFontFace.allCases)
    func faceWeightsAreOrderedLikeTheirNames(_ face: HearthFontFace) {
        let font = CTFontCreateWithName(face.postScriptName as CFString, 17, nil)
        let traits = CTFontCopyTraits(font) as NSDictionary
        let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? .nan
        switch face.weightValue {
        case 400: #expect(abs(weight) < 0.05)
        case 500: #expect(weight > 0.1 && weight < 0.3)
        case 600: #expect(weight > 0.25 && weight < 0.4)
        default: #expect(weight >= 0.35)
        }
    }

    @Test func weightsResolveToTheNearestBundledFace() {
        #expect(HearthFontFace.face(.display, weight: .regular) == .soraRegular)
        #expect(HearthFontFace.face(.display, weight: .semibold) == .soraSemiBold)
        #expect(HearthFontFace.face(.display, weight: .bold) == .soraBold)
        // Sora has no Medium: the tie goes to the heavier face.
        #expect(HearthFontFace.face(.display, weight: .medium) == .soraSemiBold)
        #expect(HearthFontFace.face(.display, weight: .black) == .soraBold)
        #expect(HearthFontFace.face(.display, weight: .light) == .soraRegular)

        #expect(HearthFontFace.face(.text, weight: .regular) == .plexSansRegular)
        #expect(HearthFontFace.face(.text, weight: .medium) == .plexSansMedium)
        #expect(HearthFontFace.face(.text, weight: .semibold) == .plexSansSemiBold)
        #expect(HearthFontFace.face(.text, weight: .bold) == .plexSansBold)

        #expect(HearthFontFace.face(.mono, weight: .regular) == .plexMonoRegular)
        #expect(HearthFontFace.face(.mono, weight: .medium) == .plexMonoMedium)
        // Plex Mono is bundled without Bold.
        #expect(HearthFontFace.face(.mono, weight: .bold) == .plexMonoSemiBold)
    }

    @Test func registeringTwiceIsHarmless() {
        HearthFonts.register()
        HearthFonts.register()
        #expect(HearthFontFace.allCases.allSatisfy(HearthFonts.isRegistered))
    }

    @Test func bundledFontsStayUnderBudget() throws {
        let bytes = try HearthFontRegistration.bundledFontURLs().reduce(0) { total, url in
            total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        #expect(HearthFontRegistration.bundledFontURLs().count == HearthFontFace.allCases.count)
        #expect(bytes < 3_000_000)
    }
}
