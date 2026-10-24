import Foundation
import Testing
@testable import PlayerKit

@Test(arguments: [
    ("http://h/live.m3u8", StreamFormat.unknown, EngineKind.avPlayer),
    ("http://h/movie.mp4", .unknown, .avPlayer),
    ("http://h/play/live.php?stream=1&extension=ts", .unknown, .vlc),
    ("http://h/movie.mkv", .unknown, .vlc),
    ("http://h/x", .hls, .avPlayer),
    ("http://h/x", .mpegts, .vlc),
])
func engineChoice(url: String, format: StreamFormat, expected: EngineKind) {
    let stream = StreamDescriptor(url: URL(string: url)!, format: format)
    #expect(EngineChooser.choose(for: stream) == expected)
}
