import CryptoKit
import Foundation

/// Salted PIN hashes (PAR-3). Pure, tested.
public enum PINHasher {
    public static func makeSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
    }

    public static func hash(pin: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + ":" + pin).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func isValidPIN(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy(\.isASCII) && pin.allSatisfy(\.isNumber)
    }
}

/// Adult categories, matched by name (PAR-1).
public enum AdultContentFilter {
    public static func isAdult(categoryName: String) -> Bool {
        let name = categoryName.lowercased()
        return ["adult", "xxx", "18+", "porn"].contains { name.contains($0) }
    }
}
