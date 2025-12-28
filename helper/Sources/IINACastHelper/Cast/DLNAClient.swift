import Foundation

/// DLNA/UPnP Client using SOAP over HTTP
/// Uses AVTransport and RenderingControl services
actor DLNAClient {
    private let baseURL: URL
    private var controlURL: URL?
    private var renderingControlURL: URL?

    private let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        self.session = URLSession.shared

        // Default control URLs (may be overridden after device description fetch)
        self.controlURL = baseURL.appendingPathComponent("AVTransport/control")
        self.renderingControlURL = baseURL.appendingPathComponent("RenderingControl/control")
    }

    // MARK: - Device Description

    func fetchDeviceDescription() async throws {
        let descURL = baseURL.appendingPathComponent("description.xml")
        let (data, _) = try await session.data(from: descURL)

        // Parse XML to find service control URLs
        let xml = String(data: data, encoding: .utf8) ?? ""
        // Simple parsing - in production use XMLParser
        if let avTransportMatch = xml.range(of: "AVTransport.*?<controlURL>(.*?)</controlURL>", options: .regularExpression) {
            let controlPath = String(xml[avTransportMatch])
            if let pathMatch = controlPath.range(of: "<controlURL>(.*?)</controlURL>", options: .regularExpression) {
                let path = String(controlPath[pathMatch]).replacingOccurrences(of: "<controlURL>", with: "").replacingOccurrences(of: "</controlURL>", with: "")
                controlURL = URL(string: path, relativeTo: baseURL)
            }
        }
    }

    // MARK: - AVTransport Actions

    func setAVTransportURI(_ uri: String, metadata: String? = nil) async throws {
        let didlMetadata = metadata ?? buildDIDLMetadata(for: uri)
        let escapedMetadata = didlMetadata
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        let args = """
        <InstanceID>0</InstanceID>
        <CurrentURI>\(uri)</CurrentURI>
        <CurrentURIMetaData>\(escapedMetadata)</CurrentURIMetaData>
        """

        try await sendAVTransportAction("SetAVTransportURI", arguments: args)
    }

    func play(speed: String = "1") async throws {
        let args = """
        <InstanceID>0</InstanceID>
        <Speed>\(speed)</Speed>
        """

        try await sendAVTransportAction("Play", arguments: args)
    }

    func pause() async throws {
        let args = "<InstanceID>0</InstanceID>"
        try await sendAVTransportAction("Pause", arguments: args)
    }

    func stop() async throws {
        let args = "<InstanceID>0</InstanceID>"
        try await sendAVTransportAction("Stop", arguments: args)
    }

    func seek(to position: Double) async throws {
        let timeString = formatTime(position)
        let args = """
        <InstanceID>0</InstanceID>
        <Unit>REL_TIME</Unit>
        <Target>\(timeString)</Target>
        """

        try await sendAVTransportAction("Seek", arguments: args)
    }

    func getPositionInfo() async throws -> (position: Double, duration: Double, state: String) {
        let args = "<InstanceID>0</InstanceID>"
        let response = try await sendAVTransportAction("GetPositionInfo", arguments: args)

        // Parse response
        let position = parseTime(extractXMLValue(response, tag: "RelTime"))
        let duration = parseTime(extractXMLValue(response, tag: "TrackDuration"))

        return (position, duration, "PLAYING")
    }

    func getTransportInfo() async throws -> String {
        let args = "<InstanceID>0</InstanceID>"
        let response = try await sendAVTransportAction("GetTransportInfo", arguments: args)

        return extractXMLValue(response, tag: "CurrentTransportState")
    }

    // MARK: - RenderingControl Actions

    func setVolume(_ volume: Int) async throws {
        let args = """
        <InstanceID>0</InstanceID>
        <Channel>Master</Channel>
        <DesiredVolume>\(volume)</DesiredVolume>
        """

        try await sendRenderingControlAction("SetVolume", arguments: args)
    }

    func getVolume() async throws -> Int {
        let args = """
        <InstanceID>0</InstanceID>
        <Channel>Master</Channel>
        """

        let response = try await sendRenderingControlAction("GetVolume", arguments: args)
        return Int(extractXMLValue(response, tag: "CurrentVolume")) ?? 0
    }

    func setMute(_ muted: Bool) async throws {
        let args = """
        <InstanceID>0</InstanceID>
        <Channel>Master</Channel>
        <DesiredMute>\(muted ? "1" : "0")</DesiredMute>
        """

        try await sendRenderingControlAction("SetMute", arguments: args)
    }

    // MARK: - SOAP Helpers

    @discardableResult
    private func sendAVTransportAction(_ action: String, arguments: String) async throws -> String {
        return try await sendSOAPAction(
            service: "AVTransport",
            serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
            action: action,
            arguments: arguments,
            controlURL: controlURL ?? baseURL.appendingPathComponent("AVTransport/control")
        )
    }

    @discardableResult
    private func sendRenderingControlAction(_ action: String, arguments: String) async throws -> String {
        return try await sendSOAPAction(
            service: "RenderingControl",
            serviceType: "urn:schemas-upnp-org:service:RenderingControl:1",
            action: action,
            arguments: arguments,
            controlURL: renderingControlURL ?? baseURL.appendingPathComponent("RenderingControl/control")
        )
    }

    private func sendSOAPAction(service: String, serviceType: String, action: String, arguments: String, controlURL: URL) async throws -> String {
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:\(action) xmlns:u="\(serviceType)">
                    \(arguments)
                </u:\(action)>
            </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = soapBody.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CastError.dlnaError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CastError.dlnaError("HTTP \(httpResponse.statusCode): \(body)")
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - DIDL-Lite Metadata

    private func buildDIDLMetadata(for uri: String) -> String {
        let filename = URL(string: uri)?.lastPathComponent ?? "Media"
        let mimeType = guessMimeType(uri)

        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
            <item id="0" parentID="-1" restricted="1">
                <dc:title>\(filename)</dc:title>
                <upnp:class>object.item.videoItem</upnp:class>
                <res protocolInfo="http-get:*:\(mimeType):DLNA.ORG_FLAGS=01700000000000000000000000000000">\(uri)</res>
            </item>
        </DIDL-Lite>
        """
    }

    private func guessMimeType(_ uri: String) -> String {
        let ext = URL(string: uri)?.pathExtension.lowercased() ?? ""
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/avi"
        case "webm": return "video/webm"
        case "ts": return "video/mp2t"
        default: return "video/mp4"
        }
    }

    // MARK: - Time Helpers

    private func formatTime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    private func parseTime(_ timeString: String) -> Double {
        let components = timeString.split(separator: ":")
        guard components.count == 3,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]) else {
            return 0
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    private func extractXMLValue(_ xml: String, tag: String) -> String {
        guard let startRange = xml.range(of: "<\(tag)>"),
              let endRange = xml.range(of: "</\(tag)>") else {
            return ""
        }
        return String(xml[startRange.upperBound..<endRange.lowerBound])
    }
}
