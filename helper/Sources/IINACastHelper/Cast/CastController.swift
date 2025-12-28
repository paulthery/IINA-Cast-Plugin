import Foundation
import OpenCastSwift

/// Controls casting to Chromecast and DLNA devices
actor CastController {
    static let shared = CastController()
    
    private var currentDevice: CastDevice?
    private var chromecastClient: CastClient?
    // private var dlnaClient: DLNAClient?
    
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
            client.disconnect()
            chromecastClient = nil
        }
        
        // Stop DLNA session if active
        
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
        // Parse host and port from address
        let components = device.address.split(separator: ":")
        guard components.count == 2,
              let port = UInt16(components[1]) else {
            throw CastError.invalidAddress
        }
        
        let host = String(components[0])
        
        // Create Chromecast client
        let scanner = CastDeviceScanner()
        // In real implementation, use discovered device directly
        
        // For now, create media info and load
        let mediaInfo = CastMediaInfo(
            contentId: mediaUrl,
            streamType: .buffered,
            contentType: "video/mp4"
        )
        
        // TODO: Connect to device and load media
        // This requires proper OpenCastSwift integration
        
        print("Starting Chromecast session to \(host):\(port) with \(mediaUrl)")
    }
    
    // MARK: - DLNA Implementation
    
    private func startDLNASession(device: CastDevice, mediaUrl: String, position: Double) async throws {
        // DLNA uses SOAP over HTTP
        // Send SetAVTransportURI action
        
        guard let baseURL = URL(string: device.address) else {
            throw CastError.invalidAddress
        }
        
        let controlURL = baseURL.appendingPathComponent("AVTransport/control")
        
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                    <InstanceID>0</InstanceID>
                    <CurrentURI>\(mediaUrl)</CurrentURI>
                    <CurrentURIMetaData></CurrentURIMetaData>
                </u:SetAVTransportURI>
            </s:Body>
        </s:Envelope>
        """
        
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = soapBody.data(using: .utf8)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CastError.dlnaError
        }
        
        // Send Play action
        try await sendDLNAAction(controlURL: controlURL, action: "Play")
        
        // Seek if position > 0
        if position > 0 {
            try await seek(to: position)
        }
        
        print("Started DLNA session to \(device.name)")
    }
    
    private func sendDLNAAction(controlURL: URL, action: String, args: String = "<Speed>1</Speed>") async throws {
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:\(action) xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                    <InstanceID>0</InstanceID>
                    \(args)
                </u:\(action)>
            </s:Body>
        </s:Envelope>
        """
        
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = soapBody.data(using: .utf8)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CastError.dlnaError
        }
    }
    
    // MARK: - Playback Control
    
    private func play() async throws {
        isPaused = false
        
        if currentDevice?.type == "chromecast" {
            // chromecastClient?.play()
        } else if currentDevice?.type == "dlna" {
            // Send DLNA Play
        }
    }
    
    private func pause() async throws {
        isPaused = true
        
        if currentDevice?.type == "chromecast" {
            // chromecastClient?.pause()
        } else if currentDevice?.type == "dlna" {
            // Send DLNA Pause
        }
    }
    
    private func seek(to position: Double) async throws {
        currentPosition = position
        
        if currentDevice?.type == "chromecast" {
            // chromecastClient?.seek(to: position)
        } else if currentDevice?.type == "dlna" {
            // Format time for DLNA (HH:MM:SS)
            let hours = Int(position) / 3600
            let minutes = (Int(position) % 3600) / 60
            let seconds = Int(position) % 60
            let timeString = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            
            // Send DLNA Seek
        }
    }
    
    private func setVolume(_ level: Double) async throws {
        // Volume control implementation
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
    case dlnaError
    case chromecastError
    
    var errorDescription: String? {
        switch self {
        case .deviceNotFound: return "Device not found"
        case .unsupportedProtocol: return "Unsupported protocol"
        case .notCasting: return "Not currently casting"
        case .unknownAction: return "Unknown control action"
        case .invalidAddress: return "Invalid device address"
        case .connectionFailed: return "Failed to connect to device"
        case .dlnaError: return "DLNA operation failed"
        case .chromecastError: return "Chromecast operation failed"
        }
    }
}
