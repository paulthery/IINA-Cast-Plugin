import Foundation
import Network

/// Manages discovery of Chromecast, DLNA, and AirPlay devices
actor DeviceDiscovery {
    static let shared = DeviceDiscovery()

    private var chromecastBrowser: NWBrowser?
    private var airplayBrowser: NWBrowser?
    private var ssdpSocket: SSDPDiscovery?

    private var devices: [String: CastDevice] = [:]

    private init() {}

    // MARK: - Public API

    func startDiscovery() async {
        await startChromecastDiscovery()
        await startDLNADiscovery()
        await startAirPlayDiscovery()
    }

    func stopDiscovery() {
        chromecastBrowser?.cancel()
        chromecastBrowser = nil
        airplayBrowser?.cancel()
        airplayBrowser = nil
        ssdpSocket?.stop()
        ssdpSocket = nil
    }

    func getDevices() -> [CastDevice] {
        return Array(devices.values).sorted { $0.name < $1.name }
    }

    func getDevice(id: String) -> CastDevice? {
        return devices[id]
    }

    func refreshDevices() async {
        devices.removeAll()
        await startDiscovery()
    }

    // MARK: - Chromecast Discovery (mDNS/Bonjour)

    private func startChromecastDiscovery() async {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        chromecastBrowser = NWBrowser(
            for: .bonjour(type: "_googlecast._tcp", domain: nil),
            using: parameters
        )

        chromecastBrowser?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Chromecast discovery ready")
            case .failed(let error):
                print("Chromecast discovery failed: \(error)")
            default:
                break
            }
        }

        chromecastBrowser?.browseResultsChangedHandler = { [weak self] results, _ in
            Task {
                await self?.handleChromecastResults(results)
            }
        }

        chromecastBrowser?.start(queue: .main)
    }

    private func handleChromecastResults(_ results: Set<NWBrowser.Result>) async {
        for result in results {
            if case .service(let name, let type, let domain, _) = result.endpoint {
                await resolveChromecast(name: name, type: type, domain: domain)
            }
        }
    }

    private func resolveChromecast(name: String, type: String, domain: String) async {
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let innerEndpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = innerEndpoint {

                    let hostString = "\(host)".replacingOccurrences(of: "%.*", with: "", options: .regularExpression)
                    let device = CastDevice(
                        id: "chromecast-\(name.hashValue)",
                        name: name,
                        type: "chromecast",
                        address: hostString,
                        port: Int(port.rawValue),
                        capabilities: DeviceCapabilities(
                            maxWidth: 3840,
                            maxHeight: 2160,
                            codecs: ["h264", "hevc", "vp8", "vp9"],
                            hdr: true,
                            dolbyVision: false,
                            audioCodecs: ["aac", "ac3", "eac3", "opus"],
                            subtitleFormats: ["vtt"]
                        )
                    )

                    Task {
                        await self?.addDevice(device)
                    }
                }
                connection.cancel()
            }
        }

        connection.start(queue: .main)

        // Timeout after 5 seconds
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        connection.cancel()
    }

    // MARK: - DLNA Discovery (SSDP)

    private func startDLNADiscovery() async {
        ssdpSocket = SSDPDiscovery { [weak self] device in
            Task {
                await self?.addDevice(device)
            }
        }
        ssdpSocket?.start()
    }

    // MARK: - AirPlay Discovery (mDNS)

    private func startAirPlayDiscovery() async {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        airplayBrowser = NWBrowser(
            for: .bonjour(type: "_airplay._tcp", domain: nil),
            using: parameters
        )

        airplayBrowser?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("AirPlay discovery ready")
            case .failed(let error):
                print("AirPlay discovery failed: \(error)")
            default:
                break
            }
        }

        airplayBrowser?.browseResultsChangedHandler = { [weak self] results, _ in
            Task {
                await self?.handleAirPlayResults(results)
            }
        }

        airplayBrowser?.start(queue: .main)
    }

    private func handleAirPlayResults(_ results: Set<NWBrowser.Result>) async {
        for result in results {
            if case .service(let name, let type, let domain, _) = result.endpoint {
                await resolveAirPlay(name: name, type: type, domain: domain)
            }
        }
    }

    private func resolveAirPlay(name: String, type: String, domain: String) async {
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let innerEndpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = innerEndpoint {

                    let hostString = "\(host)".replacingOccurrences(of: "%.*", with: "", options: .regularExpression)
                    let device = CastDevice(
                        id: "airplay-\(name.hashValue)",
                        name: name,
                        type: "airplay",
                        address: hostString,
                        port: Int(port.rawValue),
                        capabilities: DeviceCapabilities(
                            maxWidth: 3840,
                            maxHeight: 2160,
                            codecs: ["h264", "hevc"],
                            hdr: true,
                            dolbyVision: true,
                            audioCodecs: ["aac", "alac"],
                            subtitleFormats: ["vtt"]
                        )
                    )

                    Task {
                        await self?.addDevice(device)
                    }
                }
                connection.cancel()
            }
        }

        connection.start(queue: .main)

        try? await Task.sleep(nanoseconds: 5_000_000_000)
        connection.cancel()
    }

    // MARK: - Device Management

    private func addDevice(_ device: CastDevice) {
        devices[device.id] = device
        print("Found device: \(device.name) (\(device.type)) at \(device.address):\(device.port)")
    }

    private func removeDevice(id: String) {
        devices.removeValue(forKey: id)
    }
}

// MARK: - SSDP Discovery

/// Simple SSDP implementation for DLNA device discovery
/// Uses UDP multicast to 239.255.255.250:1900
class SSDPDiscovery {
    private var socket: Int32 = -1
    private var running = false
    private var onDeviceFound: (CastDevice) -> Void
    private var discoveredLocations: Set<String> = []

    init(onDeviceFound: @escaping (CastDevice) -> Void) {
        self.onDeviceFound = onDeviceFound
    }

    func start() {
        running = true

        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.runDiscovery()
        }
    }

    func stop() {
        running = false
        if socket != -1 {
            close(socket)
            socket = -1
        }
    }

    private func runDiscovery() {
        // Create UDP socket
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket != -1 else {
            print("SSDP: Failed to create socket")
            return
        }

        // Set socket options
        var reuseAddr: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Set receive timeout
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Send M-SEARCH
        sendMSearch()

        // Receive responses
        var buffer = [UInt8](repeating: 0, count: 4096)
        while running {
            let bytesRead = recv(socket, &buffer, buffer.count, 0)
            if bytesRead > 0 {
                let data = Data(buffer[..<bytesRead])
                if let response = String(data: data, encoding: .utf8) {
                    parseResponse(response)
                }
            }
        }
    }

    private func sendMSearch() {
        let searchMessage = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 3\r
        ST: urn:schemas-upnp-org:device:MediaRenderer:1\r
        \r

        """

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")

        let data = searchMessage.data(using: .utf8)!
        data.withUnsafeBytes { ptr in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    _ = sendto(socket, ptr.baseAddress, data.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func parseResponse(_ response: String) {
        // Extract LOCATION header
        guard let locationRange = response.range(of: "LOCATION: ", options: .caseInsensitive),
              let endRange = response.range(of: "\r\n", range: locationRange.upperBound..<response.endIndex) else {
            return
        }

        let location = String(response[locationRange.upperBound..<endRange.lowerBound])

        // Skip if already discovered
        guard !discoveredLocations.contains(location) else { return }
        discoveredLocations.insert(location)

        // Fetch device description
        Task {
            await fetchDeviceDescription(location: location)
        }
    }

    private func fetchDeviceDescription(location: String) async {
        guard let url = URL(string: location) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let xml = String(data: data, encoding: .utf8) else { return }

            // Parse device info (simplified)
            let friendlyName = extractXMLValue(xml, tag: "friendlyName")
            let udn = extractXMLValue(xml, tag: "UDN")

            guard !friendlyName.isEmpty else { return }

            let baseURL = url.deletingLastPathComponent()
            let device = CastDevice(
                id: "dlna-\(udn.hashValue)",
                name: friendlyName,
                type: "dlna",
                address: baseURL.absoluteString,
                port: url.port ?? 80,
                capabilities: DeviceCapabilities(
                    maxWidth: 3840,
                    maxHeight: 2160,
                    codecs: ["h264", "hevc"],
                    hdr: true,
                    dolbyVision: false,
                    audioCodecs: ["aac", "ac3", "dts"],
                    subtitleFormats: ["srt"]
                )
            )

            onDeviceFound(device)

        } catch {
            print("SSDP: Failed to fetch device description: \(error)")
        }
    }

    private func extractXMLValue(_ xml: String, tag: String) -> String {
        guard let startRange = xml.range(of: "<\(tag)>"),
              let endRange = xml.range(of: "</\(tag)>", range: startRange.upperBound..<xml.endIndex) else {
            return ""
        }
        return String(xml[startRange.upperBound..<endRange.lowerBound])
    }
}
