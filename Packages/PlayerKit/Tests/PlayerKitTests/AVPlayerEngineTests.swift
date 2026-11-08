import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import PlayerKit

/// The AVPlayer engine itself on a short movie this test writes, so the
/// resume path runs against the real AVFoundation of whatever OS runs it
/// (the Mac's, and the iOS simulator's in `AllPackageTests`).
@MainActor
@Suite("AVPlayerEngine")
struct AVPlayerEngineTests {
    @Test func aResumeGoesToTheItemBeforeItLoadsAndLandsThere() async throws {
        let file = try await TestMovie.write(seconds: 12)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = AVPlayerEngine()
        engine.isMuted = true
        engine.load(StreamDescriptor(url: file, format: .mp4, startPosition: 8))
        if #available(iOS 27, tvOS 27, macOS 27, *) {
            // Seeking once ready came after the first segment was fetched,
            // 16 MB on the owner's provider, only to be thrown away.
            #expect(engine.resumedBeforeLoading)
        }
        engine.play()
        let landed = await waitFor { engine.duration != nil && engine.currentTime >= 7.5 }
        #expect(landed, "at \(engine.currentTime) s of \(engine.duration ?? 0)")
        #expect(engine.currentTime < 11)
        engine.stop()
    }

    @Test func aMovieFromTheStartIsNotSeeked() async throws {
        let file = try await TestMovie.write(seconds: 4)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = AVPlayerEngine()
        engine.isMuted = true
        engine.load(StreamDescriptor(url: file, format: .mp4))
        #expect(!engine.resumedBeforeLoading)
        engine.play()
        #expect(await waitFor { engine.duration != nil })
        #expect(engine.currentTime < 2)
        engine.stop()
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}

/// A silent H.264 movie of grey frames, 10 a second, a keyframe each second.
enum TestMovie {
    static func write(seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hearth-test-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 96,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 10],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160,
            kCVPixelBufferHeightKey as String: 96,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(40 + frame % 160), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }
}
