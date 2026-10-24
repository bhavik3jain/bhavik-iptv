import Testing
@testable import SourceKit

@Test func macIsMaskedButRecognisable() {
    #expect(Redaction.mac("00:1A:79:AA:BB:41") == "00:1A:79:••:••:41")
}

@Test func redactedConfigurationHidesLogins() {
    let config = SourceConfiguration(name: "P", kind: .xtream, serverURL: "http://x.example", username: "u", password: "p")
    #expect(config.redacted.username == "•••")
    #expect(config.redacted.password == "•••")
    #expect(config.redacted.serverURL == "http://x.example")
}
