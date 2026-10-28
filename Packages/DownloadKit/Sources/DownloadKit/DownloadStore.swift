import Foundation

/// The records as one JSON file in the downloads folder. A handful of rows
/// on one device: no database, no iCloud.
struct DownloadStore: Sendable {
    let folder: URL

    var fileURL: URL { folder.appendingPathComponent("downloads.json") }

    func load() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DownloadRecord].self, from: data)) ?? []
    }

    func save(_ records: [DownloadRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Names and sizes on disk.
enum DownloadFiles {
    /// A file name from an item key (`<source>/movie/<id>`): letters, digits,
    /// dots and dashes, the rest as underscores.
    static func safeName(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
    }

    /// The extension a downloaded file is saved under: the link's own when it
    /// has a short one, else what the server suggested, else mp4.
    static func fileExtension(url: URL?, suggestedFilename: String?) -> String {
        if let ext = url?.pathExtension.lowercased(), (1...5).contains(ext.count), ext != "php" {
            return ext
        }
        if let suggested = suggestedFilename.map({ ($0 as NSString).pathExtension.lowercased() }), (1...5).contains(suggested.count) {
            return suggested
        }
        return "mp4"
    }

    /// A file's size, or everything inside a package (an HLS download is a
    /// folder of segments).
    static func size(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isFolder) else { return 0 }
        guard isFolder.boolValue else {
            return (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        for case let file as URL in manager.enumerator(at: url, includingPropertiesForKeys: keys) ?? FileManager.DirectoryEnumerator() {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// The absolute URL of a location.
    static func url(of location: DownloadLocation, folder: URL) -> URL {
        switch location {
        case .downloadsFolder(let name): folder.appendingPathComponent(name)
        case .home(let path): URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
        }
    }
}
