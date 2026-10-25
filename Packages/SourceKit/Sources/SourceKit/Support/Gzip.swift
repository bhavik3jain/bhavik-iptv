import Compression
import Foundation

/// Streaming gzip decoding with Apple's Compression framework, so guides that
/// arrive as `.xml.gz` never need a remote package (technical spec, Big files).
///
/// Compression's `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951) with no
/// wrapper, so this strips the gzip member header (RFC 1952) itself, inflates
/// the body, checks the 8-byte trailer and carries on if another member
/// follows — some servers concatenate them.
///
/// One quirk shapes the trailer step: Compression swallows every input byte
/// it's handed, even past the end of the deflate stream, and reports none
/// left over. So the end of a member is found the other way round: the
/// trailer is the 8 bytes, somewhere in the input of the call that ended the
/// stream, holding this member's CRC-32 and length — a match that can't
/// happen by chance.
struct GzipDecoder: ~Copyable {
    enum Failure: Error, Equatable {
        case notGzip
        case unsupportedMethod
        case corrupt
    }

    private enum State {
        case header
        case body
        /// The trailer starts somewhere in `carry[offset...(offset + window)]`.
        case trailer(window: Int)
        /// Between members: another may follow.
        case done
        /// The trailer couldn't be placed; whatever follows is ignored rather
        /// than misread (the member itself decoded fine).
        case ignoringRest
    }

    private var state: State = .header
    private var carry: [UInt8] = []
    private let stream: UnsafeMutablePointer<compression_stream>
    private var streamReady = false
    private let outputSize = 256 * 1024
    private let output: UnsafeMutablePointer<UInt8>
    /// CRC-32 and length (mod 2^32) of the current member's decoded bytes.
    private var crc = CRC32()
    private var memberSize: UInt32 = 0

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
                crc = CRC32()
                memberSize = 0
                state = .body
            case .body:
                let (consumed, ended) = try inflate(from: offset, emit: emit)
                if ended {
                    compression_stream_destroy(stream)
                    streamReady = false
                    // Stay at the start of this call's input: the trailer is in it.
                    state = .trailer(window: consumed)
                } else {
                    offset += consumed
                    if consumed == 0 { return }
                }
            case .trailer(let window):
                switch locateTrailer(from: offset, window: window) {
                case .found(let end):
                    offset = end
                    state = .done
                case .needMoreInput:
                    return
                case .absent:
                    offset = carry.count
                    state = .ignoringRest
                }
            case .done:
                // Another member, or padding some servers append.
                if carry.count - offset < 2 { return }
                if carry[offset] == 0x1F, carry[offset + 1] == 0x8B {
                    state = .header
                } else {
                    offset = carry.count
                    state = .ignoringRest
                }
            case .ignoringRest:
                offset = carry.count
            }
        }
    }

    /// Ends the input. A body cut short throws, so a truncated download is
    /// reported rather than read as a short guide. A missing trailer doesn't:
    /// everything it would vouch for has already been decoded.
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
        var crc = self.crc
        var size = memberSize
        defer {
            self.crc = crc
            memberSize = size
        }
        return try carry.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return (0, false) }
            stream.pointee.src_ptr = base + offset
            stream.pointee.src_size = available
            while true {
                stream.pointee.dst_ptr = output
                stream.pointee.dst_size = outputSize
                let status = compression_stream_process(stream, 0)
                let produced = outputSize - stream.pointee.dst_size
                if produced > 0 {
                    let decoded = UnsafeBufferPointer(start: output, count: produced)
                    crc.update(decoded)
                    size &+= UInt32(truncatingIfNeeded: produced)
                    emit(Data(buffer: decoded))
                }
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

    private enum TrailerSearch {
        case found(end: Int)
        case needMoreInput
        case absent
    }

    /// Finds the trailer — CRC-32 then length, little-endian — that starts
    /// within `window` bytes of `offset`.
    private func locateTrailer(from offset: Int, window: Int) -> TrailerSearch {
        let expectedCRC = crc.value
        let expectedSize = memberSize
        var start = offset
        while start <= offset + window {
            guard start + 8 <= carry.count else { return .needMoreInput }
            if Self.littleEndian(carry, at: start) == expectedCRC, Self.littleEndian(carry, at: start + 4) == expectedSize {
                return .found(end: start + 8)
            }
            start += 1
        }
        return .absent
    }

    private static func littleEndian(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
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

/// CRC-32 as gzip's trailer computes it (IEEE 802.3, reflected, polynomial
/// 0xEDB88320), table-driven.
struct CRC32: Sendable {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private var state: UInt32 = 0xFFFF_FFFF

    var value: UInt32 { state ^ 0xFFFF_FFFF }

    mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        var crc = state
        Self.table.withUnsafeBufferPointer { table in
            for byte in bytes {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        state = crc
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
