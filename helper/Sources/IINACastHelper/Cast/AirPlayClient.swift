import Foundation

/// AirPlay Client for Apple TV and AirPlay-compatible devices
/// Protocol: HTTP on port 7000, RTSP for audio on 49152
/// Video streaming: POST /play with Content-Location
actor AirPlayClient {
    private let host: String
    private let port: Int

    private let session: URLSession
    private var sessionId: String?
    private var deviceId: String?

    private var statusPollingTask: Task<Void, Never>?

    init(host: String, port: Int = 7000) {
        self.host = host
        self.port = port

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)

        // Generate session ID
        self.sessionId = UUID().uuidString
    }

    // MARK: - Server Info

    func getServerInfo() async throws -> AirPlayServerInfo {
        let url = URL(string: "http://\(host):\(port)/server-info")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addCommonHeaders(to: &request)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CastError.chromecastError("Failed to get server info")
        }

        // Parse plist response
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CastError.chromecastError("Invalid server info response")
        }

        return AirPlayServerInfo(
            model: plist["model"] as? String ?? "Unknown",
            deviceId: plist["deviceid"] as? String ?? "",
            features: plist["features"] as? Int ?? 0,
            protovers: plist["protovers"] as? String ?? "1.0",
            srcvers: plist["srcvers"] as? String ?? ""
        )
    }

    // MARK: - Video Playback

    func play(url mediaUrl: String, startPosition: Double = 0) async throws {
        let endpoint = URL(string: "http://\(host):\(port)/play")!

        // Build plist body
        let body: [String: Any] = [
            "Content-Location": mediaUrl,
            "Start-Position": startPosition / 100.0  // Fraction of duration
        ]

        let bodyData = try PropertyListSerialization.data(fromPropertyList: body, format: .binary, options: 0)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-binary-plist", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        addCommonHeaders(to: &request)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CastError.chromecastError("Failed to start AirPlay playback")
        }

        // Start polling for status
        startStatusPolling()
    }

    func stop() async throws {
        stopStatusPolling()

        let endpoint = URL(string: "http://\(host):\(port)/stop")!

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        addCommonHeaders(to: &request)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CastError.chromecastError("Failed to stop AirPlay playback")
        }
    }

    func pause() async throws {
        try await setRate(0)
    }

    func resume() async throws {
        try await setRate(1)
    }

    func seek(to position: Double) async throws {
        let endpoint = URL(string: "http://\(host):\(port)/scrub?position=\(position)")!

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        addCommonHeaders(to: &request)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CastError.chromecastError("Failed to seek")
        }
    }

    func setRate(_ rate: Double) async throws {
        let endpoint = URL(string: "http://\(host):\(port)/rate?value=\(rate)")!

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        addCommonHeaders(to: &request)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CastError.chromecastError("Failed to set rate")
        }
    }

    // MARK: - Status

    func getPlaybackInfo() async throws -> AirPlayPlaybackInfo {
        let endpoint = URL(string: "http://\(host):\(port)/playback-info")!

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        addCommonHeaders(to: &request)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return AirPlayPlaybackInfo(position: 0, duration: 0, rate: 0, readyToPlay: false)
        }

        // Parse plist response
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return AirPlayPlaybackInfo(position: 0, duration: 0, rate: 0, readyToPlay: false)
        }

        return AirPlayPlaybackInfo(
            position: plist["position"] as? Double ?? 0,
            duration: plist["duration"] as? Double ?? 0,
            rate: plist["rate"] as? Double ?? 0,
            readyToPlay: plist["readyToPlay"] as? Bool ?? false
        )
    }

    // MARK: - Photos

    func showPhoto(data: Data) async throws {
        let endpoint = URL(string: "http://\(host):\(port)/photo")!

        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = data
        addCommonHeaders(to: &request)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CastError.chromecastError("Failed to display photo")
        }
    }

    // MARK: - Internal

    private func addCommonHeaders(to request: inout URLRequest) {
        request.setValue("MediaControl/1.0", forHTTPHeaderField: "User-Agent")
        if let sessionId = sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "X-Apple-Session-ID")
        }
        if let deviceId = deviceId {
            request.setValue(deviceId, forHTTPHeaderField: "X-Apple-Device-ID")
        }
    }

    private func startStatusPolling() {
        statusPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                let _ = try? await getPlaybackInfo()
            }
        }
    }

    private func stopStatusPolling() {
        statusPollingTask?.cancel()
        statusPollingTask = nil
    }

    func disconnect() {
        stopStatusPolling()
    }
}

// MARK: - Models

struct AirPlayServerInfo {
    let model: String
    let deviceId: String
    let features: Int
    let protovers: String
    let srcvers: String
}

struct AirPlayPlaybackInfo {
    let position: Double
    let duration: Double
    let rate: Double
    let readyToPlay: Bool

    var isPlaying: Bool {
        return rate > 0
    }

    var isPaused: Bool {
        return rate == 0 && duration > 0
    }
}
