import Foundation
import Vapor

// MARK: - Device Models

struct CastDevice: Codable, Sendable {
    let id: String
    let name: String
    let type: String  // "chromecast", "dlna", or "airplay"
    let address: String
    let port: Int
    var capabilities: DeviceCapabilities?

    init(id: String, name: String, type: String, address: String, port: Int = 0, capabilities: DeviceCapabilities? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.address = address
        self.port = port
        self.capabilities = capabilities
    }
}

struct DeviceCapabilities: Codable, Sendable {
    var maxWidth: Int = 1920
    var maxHeight: Int = 1080
    var codecs: [String] = ["h264"]
    var hdr: Bool = false
    var dolbyVision: Bool = false
    var audioCodecs: [String] = ["aac", "ac3"]
    var subtitleFormats: [String] = ["vtt"]
}

// MARK: - Cast Status

struct CastStatus: Codable, Sendable {
    let casting: Bool
    let deviceId: String?
    let deviceName: String?
    let position: Double
    let duration: Double
    let paused: Bool
    var state: String = "idle"  // idle, buffering, playing, paused, stopped, error
    var bufferPercent: Double = 0
}

// MARK: - API Request Models

struct CastRequest: Content {
    let deviceId: String
    let mediaUrl: String
    let position: Double?
    let mode: String?  // "direct", "remux", "transcode"
    let transcodeOptions: TranscodeOptions?
    let subtitles: SubtitleOptions?
}

struct TranscodeOptions: Codable {
    let videoBitrate: Int?
    let resolution: String?  // "source", "2160p", "1080p", "720p"
    let audioTrack: Int?
    let audioCodec: String?  // "source", "aac", "ac3"
}

struct SubtitleOptions: Codable {
    let track: Int?
    let externalUrl: String?
    let mode: String?  // "sidecar", "burnin", "off"
}

struct ControlRequest: Content {
    let action: String  // "play", "pause", "seek", "volume", "stop"
    let value: Double?
}

// MARK: - Media Info

struct MediaInfo: Codable, Sendable {
    let path: String
    let duration: Double
    let container: String
    let videoCodec: String
    let audioCodec: String
    let width: Int
    let height: Int
    let bitrate: Int
    let hdr: Bool
    let audioTracks: [AudioTrack]
    let subtitleTracks: [SubtitleTrack]
}

struct AudioTrack: Codable, Sendable {
    let index: Int
    let codec: String
    let language: String?
    let title: String?
    let channels: Int
}

struct SubtitleTrack: Codable, Sendable {
    let index: Int
    let codec: String
    let language: String?
    let title: String?
    let forced: Bool
}

// MARK: - Session

struct CastSession: Sendable {
    let id: String
    let device: CastDevice
    let mediaUrl: String
    let startTime: Date
    var position: Double
    var state: SessionState

    enum SessionState: String, Sendable {
        case connecting
        case buffering
        case playing
        case paused
        case stopped
        case error
    }
}
