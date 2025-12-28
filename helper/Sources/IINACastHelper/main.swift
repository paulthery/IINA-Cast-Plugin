import Vapor
import Foundation
import ArgumentParser

// MARK: - CLI Entry Point

@main
struct IINACastHelper: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iina-cast-helper",
        abstract: "Helper process for IINA Cast Plugin"
    )
    
    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: Int = 9876
    
    @Flag(name: .long, help: "Run as daemon")
    var daemon: Bool = false
    
    func run() async throws {
        if daemon {
            // Daemonize: detach from terminal
            // In production, use proper daemonization
        }
        
        let app = try await Application.make(.production)
        defer { Task { try? await app.asyncShutdown() } }
        
        // Configure
        app.http.server.configuration.port = port
        app.http.server.configuration.hostname = "127.0.0.1"
        
        // Setup routes
        try routes(app)
        
        // Start discovery
        let discovery = DeviceDiscovery.shared
        await discovery.startDiscovery()
        
        print("IINA Cast Helper running on port \(port)")
        try await app.execute()
    }
}

// MARK: - Routes

func routes(_ app: Application) throws {
    
    // Health check
    app.get("health") { req in
        return ["status": "ok"]
    }
    
    // List discovered devices
    app.get("devices") { req async -> Response in
        let devices = await DeviceDiscovery.shared.getDevices()
        let encoder = JSONEncoder()
        let data = try! encoder.encode(devices)
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: data)
        )
    }
    
    // Start casting
    app.post("cast") { req async throws -> Response in
        let payload = try req.content.decode(CastRequest.self)
        
        do {
            try await CastController.shared.startCast(
                deviceId: payload.deviceId,
                mediaUrl: payload.mediaUrl,
                position: payload.position
            )
            return Response(status: .ok, body: .init(string: #"{"status":"casting"}"#))
        } catch {
            throw Abort(.badRequest, reason: error.localizedDescription)
        }
    }
    
    // Control playback
    app.post("control") { req async throws -> Response in
        let payload = try req.content.decode(ControlRequest.self)
        
        try await CastController.shared.control(
            action: payload.action,
            value: payload.value
        )
        
        return Response(status: .ok, body: .init(string: #"{"status":"ok"}"#))
    }
    
    // Get current status
    app.get("status") { req async -> Response in
        let status = await CastController.shared.getStatus()
        let encoder = JSONEncoder()
        let data = try! encoder.encode(status)
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: data)
        )
    }
    
    // Stop casting
    app.post("stop") { req async throws -> Response in
        try await CastController.shared.stopCast()
        return Response(status: .ok, body: .init(string: #"{"status":"stopped"}"#))
    }
    
    // Shutdown helper
    app.post("shutdown") { req -> Response in
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            exit(0)
        }
        return Response(status: .ok, body: .init(string: #"{"status":"shutting_down"}"#))
    }
    
    // Serve media files (for casting local files)
    app.get("media", "**") { req -> Response in
        let path = req.parameters.getCatchall().joined(separator: "/")
        let filePath = "/tmp/iina-cast-media/\(path)"
        
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw Abort(.notFound)
        }
        
        return req.fileio.streamFile(at: filePath)
    }
}

// MARK: - Request/Response Models

struct CastRequest: Content {
    let deviceId: String
    let mediaUrl: String
    let position: Double?
}

struct ControlRequest: Content {
    let action: String
    let value: Double?
}

struct CastDevice: Codable {
    let id: String
    let name: String
    let type: String  // "chromecast" or "dlna"
    let address: String
}

struct CastStatus: Codable {
    let casting: Bool
    let deviceId: String?
    let deviceName: String?
    let position: Double
    let duration: Double
    let paused: Bool
}
