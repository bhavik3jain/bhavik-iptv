import Compression
import Foundation

/// Streaming gzip decoding with Apple's Compression framework, so guides that
/// arrive as `.xml.gz` never need a remote package (technical spec, Big files).
///
/// Compression's `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951) with no
/// wrapper, so this strips the gzip member header (RFC 1952) itself, inflates
/// the body, skips the 8-byte trailer and carries on if another member
/// follows — some servers concatenate them.
struct GzipDecoder: ~Copyable {
    enum Failure: Error, Equatable {
        case notGzip
        case unsupportedMethod
        case corrupt
    }

    private enum State {
        case header
        case body
        case trailer(remaining: Int)
        case done
    }

    private var state: State = .header
    private var carry: [UInt8] = []
    private let stream: UnsafeMutablePointer<compression_stream>
    private var streamReady = false
    private let outputSize = 256 * 1024
    private let output: UnsafeMutablePointer<UInt8>

    init() {
        stream = .allocate(capacity: 1)
        output = .allocate(capacity: outputSize)
    }

    deinit {
        if streamReady { compression_stream_destroy(stream) }
        stream.deallocate()
        output.deallocate()
    }

    /// True for data that starts with the gzip magic number.
    static func isGzip(_ prefix: some Collection<UInt8>) -> Bool {
        var iterator = prefix.makeIterator()
        return iterator.next() == 0x1F && iterator.next() == 0x8B
    }

    /// Decodes a whole buffer (tests, small files).
    static func decompress(_ data: Data) throws -> Data {
        var decoder = GzipDecoder()
        var result = Data()
        try decoder.feed(data) { result.append($0) }
        try decoder.finish()
        return result
    }

    /// Feeds the next compressed bytes; `emit` receives decoded bytes as they
    /// come, possibly several times per call.
    mutating func feed(_ data: some DataProtocol, emit: (Data) -> Void) throws {
        carry.append(contentsOf: data)
        var offset = 0
        defer { carry.removeFirst(min(offset, carry.count)) }
        while offset < carry.count {
            switch state {
            case .header:
                guard let length = try Self.headerLength(carry, from: offset) else { return }
                offset += length
                try startStream()
                state = .body
            case .body:
                let (consumed, ended) = try inflate(from: offset, emit: emit)
                offset += consumed
                if ended {
                    compression_stream_destroy(stream)
                    streamReady = false
                    state = .trailer(remaining: 8)
                } else if consumed == 0 {
                    return
                }
            case .trailer(let remaining):
                let skip = min(remaining, carry.count - offset)
                offset += skip
                state = remaining - skip == 0 ? .done : .trailer(remaining: remaining - skip)
            case .done:
                // Another member, or padding some servers append.
                if carry.count - offset < 2 { return }
                if carry[offset] == 0x1F, carry[offset + 1] == 0x8B {
                    state = .header
                } else {
                    offset = carry.count
                }
            }
        }
    }

    /// Ends the input. A body cut short throws, so a truncated download is
    /// reported rather than read as a short guide.
    mutating func finish() throws {
        if case .body = state { throw Failure.corrupt }
        if case .header = state, !carry.isEmpty { throw Failure.corrupt }
    }

    // MARK: Steps

    private mutating func startStream() throws {
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.corrupt
        }
        streamReady = true
    }

    /// Inflates as much of `carry[offset...]` as it can.
    private mutating func inflate(from offset: Int, emit: (Data) -> Void) throws -> (consumed: Int, ended: Bool) {
        let available = carry.count - offset
        let stream = self.stream
        let output = self.output
        let outputSize = self.outputSize
        return try carry.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return (0, false) }
            stream.pointee.src_ptr = base + offset
            stream.pointee.src_size = available
            while true {
                stream.pointee.dst_ptr = output
                stream.pointee.dst_size = outputSize
                let status = compression_stream_process(stream, 0)
                let produced = outputSize - stream.pointee.dst_size
                if produced > 0 { emit(Data(bytes: output, count: produced)) }
                switch status {
                case COMPRESSION_STATUS_END:
                    return (available - stream.pointee.src_size, true)
                case COMPRESSION_STATUS_OK:
                    // Keep going while output fills up; stop once input is used.
                    if stream.pointee.dst_size == 0 { continue }
                    return (available - stream.pointee.src_size, false)
                default:
                    throw Failure.corrupt
                }
            }
        }
    }

    /// The length of the gzip member header at `offset`, nil when more bytes
    /// are needed to know.
    static func headerLength(_ bytes: [UInt8], from offset: Int) throws -> Int? {
        let available = bytes.count - offset
        guard available >= 10 else {
            if available >= 2, !(bytes[offset] == 0x1F && bytes[offset + 1] == 0x8B) { throw Failure.notGzip }
            return nil
        }
        guard bytes[offset] == 0x1F, bytes[offset + 1] == 0x8B else { throw Failure.notGzip }
        guard bytes[offset + 2] == 8 else { throw Failure.unsupportedMethod }
        let flags = bytes[offset + 3]
        var cursor = offset + 10
        if flags & 0x04 != 0 { // FEXTRA
            guard cursor + 2 <= bytes.count else { return nil }
            let length = Int(bytes[cursor]) | Int(bytes[cursor + 1]) << 8
            cursor += 2 + length
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 { // FNAME, FCOMMENT
            while true {
                guard cursor < bytes.count else { return nil }
                defer { cursor += 1 }
                if bytes[cursor] == 0 { break }
            }
        }
        if flags & 0x02 != 0 { cursor += 2 } // FHCRC
        guard cursor <= bytes.count else { return nil }
        return cursor - offset
    }
}

/// An `InputStream` that reads a gzip file and hands out the decoded bytes,
/// so `XMLParser(stream:)` parses a compressed guide without the whole thing
/// (or a decompressed copy) ever existing at once.
///
/// Used from one thread only — the parser's — which `XMLParser` reads
/// synchronously; it never schedules the stream on a run loop.
final class GunzipInputStream: InputStream {
    private let source: InputStream
    private var decoder = GzipDecoder()
    private var pending = Data()
    private var pendingOffset = 0
    private var status: Stream.Status = .notOpen
    private var sourceEnded = false
    private var failure: Error?
    private var chunk = [UInt8](repeating: 0, count: 64 * 1024)

    init(source: InputStream) {
        self.source = source
        super.init(data: Data())
    }

    override func open() {
        source.open()
        status = .open
    }

    override func close() {
        source.close()
        status = .closed
    }

    override var streamStatus: Stream.Status { status }
    override var streamError: Error? { failure }
    override var hasBytesAvailable: Bool { pendingOffset < pending.count || !sourceEnded }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength length: Int) -> Int {
        while pendingOffset >= pending.count {
            if sourceEnded {
                status = .atEnd
                return 0
            }
            let count = chunk.withUnsafeMutableBufferPointer { source.read($0.baseAddress!, maxLength: $0.count) }
            if count < 0 {
                failure = source.streamError ?? GzipDecoder.Failure.corrupt
                status = .error
                return -1
            }
            var decoded = Data()
            do {
                if count == 0 {
                    sourceEnded = true
                    try decoder.finish()
                } else {
                    try decoder.feed(chunk[0..<count]) { decoded.append($0) }
                }
            } catch {
                failure = error
                status = .error
                return -1
            }
            pending = decoded
            pendingOffset = 0
        }
        let count = min(length, pending.count - pendingOffset)
        pending.withUnsafeBytes { raw in
            buffer.update(from: raw.bindMemory(to: UInt8.self).baseAddress! + pendingOffset, count: count)
        }
        pendingOffset += count
        return count
    }

    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length: UnsafeMutablePointer<Int>) -> Bool {
        false
    }

    override func property(forKey key: Stream.PropertyKey) -> Any? { nil }
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { false }
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
}
