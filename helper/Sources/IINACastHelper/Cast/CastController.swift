import Foundation
import NIO
import NIOSSL

/// Controls casting to Chromecast, DLNA, and AirPlay devices
actor CastController {
    static let shared = CastController()

    private var currentDevice: CastDevice?
    private var chromecastClient: ChromecastClient?
    private var dlnaClient: DLNAClient?
    private var airplayClient: AirPlayClient?

    private var currentPosition: Double = 0
    private var currentDuration: Double = 0
    private var isPaused: Bool = false

    private init() {}

    // MARK: - Public API

    func startCast(deviceId: String, mediaUrl: String, position: Double?) async throws {
        guard let device = await DeviceDiscovery.shared.getDevice(id: deviceId) else {
            throw CastError.deviceNotFound
        }

        // Stop any existing cast
        try? await stopCast()

        currentDevice = device

        switch device.type {
        case "chromecast":
            try await startChromecastSession(device: device, mediaUrl: mediaUrl, position: position ?? 0)
        case "dlna":
            try await startDLNASession(device: device, mediaUrl: mediaUrl, position: position ?? 0)
        case "airplay":
            try await startAirPlaySession(device: device, mediaUrl: mediaUrl, position: position ?? 0)
        default:
            throw CastError.unsupportedProtocol
        }
    }

    func control(action: String, value: Double?) async throws {
        guard currentDevice != nil else {
            throw CastError.notCasting
        }

        switch action {
        case "play":
            try await play()
        case "pause":
            try await pause()
        case "seek":
            if let position = value {
                try await seek(to: position)
            }
        case "volume":
            if let level = value {
                try await setVolume(level)
            }
        default:
            throw CastError.unknownAction
        }
    }

    func stopCast() async throws {
        if let client = chromecastClient {
            await client.disconnect()
            chromecastClient = nil
        }

        if let client = airplayClient {
            try? await client.stop()
            await client.disconnect()
            airplayClient = nil
        }

        dlnaClient = nil
        currentDevice = nil
        currentPosition = 0
        currentDuration = 0
        isPaused = false
    }

    func getStatus() -> CastStatus {
        return CastStatus(
            casting: currentDevice != nil,
            deviceId: currentDevice?.id,
            deviceName: currentDevice?.name,
            position: currentPosition,
            duration: currentDuration,
            paused: isPaused
        )
    }

    // MARK: - Chromecast Implementation

    private func startChromecastSession(device: CastDevice, mediaUrl: String, position: Double) async throws {
        guard let (host, port) = parseAddress(device.address) else {
            throw CastError.invalidAddress
        }

        let client = ChromecastClient(host: host, port: port)
        chromecastClient = client

        try await client.connect()
        try await client.launchDefaultMediaReceiver()
        try await client.loadMedia(url: mediaUrl, contentType: "video/mp4", startPosition: position)

        print("Started Chromecast session to \(device.name)")
    }

    // MARK: - DLNA Implementation

    private func startDLNASession(device: CastDevice, mediaUrl: String, position: Double) async throws {
        guard let baseURL = URL(string: device.address) else {
            throw CastError.invalidAddress
        }

        let client = DLNAClient(baseURL: baseURL)
        dlnaClient = client

        try await client.setAVTransportURI(mediaUrl)
        try await client.play()

        if position > 0 {
            try await client.seek(to: position)
        }

        print("Started DLNA session to \(device.name)")
    }

    // MARK: - AirPlay Implementation

    private func startAirPlaySession(device: CastDevice, mediaUrl: String, position: Double) async throws {
        let client = AirPlayClient(host: device.address, port: device.port > 0 ? device.port : 7000)
        airplayClient = client

        try await client.play(url: mediaUrl, startPosition: position)

        print("Started AirPlay session to \(device.name)")
    }

    // MARK: - Playback Control

    private func play() async throws {
        isPaused = false

        if let client = chromecastClient {
            try await client.play()
        } else if let client = dlnaClient {
            try await client.play()
        } else if let client = airplayClient {
            try await client.resume()
        }
    }

    private func pause() async throws {
        isPaused = true

        if let client = chromecastClient {
            try await client.pause()
        } else if let client = dlnaClient {
            try await client.pause()
        } else if let client = airplayClient {
            try await client.pause()
        }
    }

    private func seek(to position: Double) async throws {
        currentPosition = position

        if let client = chromecastClient {
            try await client.seek(to: position)
        } else if let client = dlnaClient {
            try await client.seek(to: position)
        } else if let client = airplayClient {
            try await client.seek(to: position)
        }
    }

    private func setVolume(_ level: Double) async throws {
        if let client = chromecastClient {
            try await client.setVolume(level / 100.0)
        } else if let client = dlnaClient {
            try await client.setVolume(Int(level))
        }
        // Note: AirPlay volume control requires RenderingControl or system-level API
    }

    // MARK: - Helpers

    private func parseAddress(_ address: String) -> (host: String, port: Int)? {
        // Handle both "host:port" and full URLs
        if address.contains("://") {
            guard let url = URL(string: address),
                  let host = url.host else { return nil }
            return (host, url.port ?? 8009)
        }

        let components = address.split(separator: ":")
        guard components.count >= 1 else { return nil }

        let host = String(components[0])
        let port = components.count > 1 ? Int(components[1]) ?? 8009 : 8009
        return (host, port)
    }
}

// MARK: - Errors

enum CastError: Error, LocalizedError {
    case deviceNotFound
    case unsupportedProtocol
    case notCasting
    case unknownAction
    case invalidAddress
    case connectionFailed
    case dlnaError(String)
    case chromecastError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .deviceNotFound: return "Device not found"
        case .unsupportedProtocol: return "Unsupported protocol"
        case .notCasting: return "Not currently casting"
        case .unknownAction: return "Unknown control action"
        case .invalidAddress: return "Invalid device address"
        case .connectionFailed: return "Failed to connect to device"
        case .dlnaError(let msg): return "DLNA error: \(msg)"
        case .chromecastError(let msg): return "Chromecast error: \(msg)"
        case .timeout: return "Operation timed out"
        }
    }
}
