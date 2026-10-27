import Foundation
import Testing
@testable import HouseholdFeature

/// `MACAddress`: what people type for a Stalker login (SRC-1) and how
/// Household shows it (PRIV-2).
@Suite struct MACAddressTests {
    @Test(arguments: [
        "00-1a-79-aa-bb-cc",
        "001a79aabbcc",
        "00:1A:79:AA:BB:CC",
        "00.1a.79.aa.bb.cc",
        "  00 1a 79 aa bb cc \n",
        "001A.79AA.BBCC",
    ])
    func everySeparatorNormalisesToColonPairs(typed: String) {
        #expect(MACAddress.normalized(typed) == "00:1A:79:AA:BB:CC")
        #expect(MACAddress.isValid(typed))
    }

    @Test(arguments: [
        "",
        "   ",
        "00:1A:79:AA:BB",            // ten digits
        "00:1A:79:AA:BB:CC:DD",      // fourteen
        "00:1A:79:AA:BB:GG",         // G isn't hex
        "00_1a_79_aa_bb_cc",         // not a separator
        "0x001a79aabbcc",            // a prefix isn't a digit
        "MAC 00:1A:79:AA:BB:CC",
    ])
    func anythingElseIsRefused(typed: String) {
        #expect(MACAddress.normalized(typed) == nil)
        #expect(!MACAddress.isValid(typed))
    }

    @Test func anyPrefixIsAllowed() {
        // MAG boxes use 00:1A:79, but providers hand out others.
        #expect(MACAddress.normalized("d4:cf:f9:12:34:56") == "D4:CF:F9:12:34:56")
        #expect(MACAddress.normalized("11-22-33-44-55-66") == "11:22:33:44:55:66")
        #expect(MACAddress.example.hasPrefix("00:1A:79"))
    }

    @Test func formattingWhileTyping() {
        #expect(MACAddress.formattedWhileTyping("") == "")
        #expect(MACAddress.formattedWhileTyping("0") == "0")
        #expect(MACAddress.formattedWhileTyping("00") == "00")
        #expect(MACAddress.formattedWhileTyping("001") == "00:1")
        #expect(MACAddress.formattedWhileTyping("001a79") == "00:1A:79")
        // Never a trailing colon, so deleting backwards works.
        #expect(MACAddress.formattedWhileTyping("00:1A:") == "00:1A")
        // Separators and stray characters are dropped, upper case, at most twelve digits.
        #expect(MACAddress.formattedWhileTyping("zz00-1a-79") == "00:1A:79")
        #expect(MACAddress.formattedWhileTyping("001a79aabbccdd") == "00:1A:79:AA:BB:CC")
    }

    @Test func maskingKeepsTheVendorAndTheLastPair() {
        #expect(MACAddress.masked("001a79aabbcc") == "00:1A:79:••:••:CC")
        #expect(MACAddress.masked("00:1A:79:12:34:41") == "00:1A:79:••:••:41")
        // Something that isn't a MAC is hidden whole, never shown as typed.
        #expect(MACAddress.masked("not-a-mac") == "•••")
        #expect(MACAddress.masked("") == "")
    }
}
