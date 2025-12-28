import Foundation
import Network
import SwiftUPnP

/// Manages discovery of Chromecast and DLNA devices
actor DeviceDiscovery {
    static let shared = DeviceDiscovery()
    
    private var chromecastBrowser: NWBrowser?
    private var upnpManager: UPnPManager?
    
    private var devices: [String: CastDevice] = [:]
    
    private init() {}
    
    // MARK: - Public API
    
    func startDiscovery() async {
        await startChromecastDiscovery()
        await startDLNADiscovery()
    }
    
    func stopDiscovery() {
        chromecastBrowser?.cancel()
        chromecastBrowser = nil
        // Stop UPNP discovery
    }
    
    func getDevices() -> [CastDevice] {
        return Array(devices.values).sorted { $0.name < $1.name }
    }
    
    func getDevice(id: String) -> CastDevice? {
        return devices[id]
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
        
        chromecastBrowser?.browseResultsChangedHandler = { [weak self] results, changes in
            Task {
                await self?.handleChromecastResults(results)
            }
        }
        
        chromecastBrowser?.start(queue: .main)
    }
    
    private func handleChromecastResults(_ results: Set<NWBrowser.Result>) async {
        for result in results {
            if case .service(let name, _, _, _) = result.endpoint {
                // Resolve the service to get IP and metadata
                await resolveChromecast(name: name, endpoint: result.endpoint)
            }
        }
    }
    
    private func resolveChromecast(name: String, endpoint: NWEndpoint) async {
        // Create connection to resolve
        let connection = NWConnection(to: endpoint, using: .tcp)
        
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let innerEndpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = innerEndpoint {
                    
                    let device = CastDevice(
                        id: "chromecast-\(name.hashValue)",
                        name: name,
                        type: "chromecast",
                        address: "\(host):\(port)"
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
        upnpManager = UPnPManager()
        
        // SwiftUPnP provides async sequence of discovered devices
        Task {
            guard let manager = upnpManager else { return }
            
            for await device in manager.devices {
                if device.deviceType.contains("MediaRenderer") {
                    let castDevice = CastDevice(
                        id: "dlna-\(device.uuid)",
                        name: device.friendlyName,
                        type: "dlna",
                        address: device.baseURL?.absoluteString ?? ""
                    )
                    await addDevice(castDevice)
                }
            }
        }
    }
    
    // MARK: - Device Management
    
    private func addDevice(_ device: CastDevice) {
        devices[device.id] = device
        print("Found device: \(device.name) (\(device.type))")
    }
    
    private func removeDevice(id: String) {
        devices.removeValue(forKey: id)
    }
}
