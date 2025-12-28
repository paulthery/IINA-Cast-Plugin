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

    @ArgumentParser.Option(name: .shortAndLong, help: "Port to listen on")
    var port: Int = 9876

    @ArgumentParser.Option(name: .long, help: "Media server port")
    var mediaPort: Int = 9877

    @ArgumentParser.Flag(name: .long, help: "Run as daemon")
    var daemon: Bool = false

    @ArgumentParser.Flag(name: .shortAndLong, help: "Verbose logging")
    var verbose: Bool = false

    mutating func run() async throws {
        let app = try await Application.make(.production)

        // Configure
        app.http.server.configuration.port = port
        app.http.server.configuration.hostname = "127.0.0.1"

        // Setup routes
        try configureRoutes(app)

        // Register media server routes
        MediaServer.registerRoutes(app)

        // Start discovery
        let discovery = DeviceDiscovery.shared
        await discovery.startDiscovery()

        print("IINA Cast Helper running on port \(port)")
        print("Media server available on port \(port)")

        defer { Task { try? await app.asyncShutdown() } }
        try await app.execute()
    }
}

// MARK: - Routes

func configureRoutes(_ app: Application) throws {

    // Health check
    app.get("health") { req in
        return ["status": "ok", "version": "1.0.0"]
    }

    // List discovered devices
    app.get("devices") { req async -> Response in
        let devices = await DeviceDiscovery.shared.getDevices()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try! encoder.encode(devices)
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: data)
        )
    }

    // Get single device
    app.get("devices", ":id") { req async throws -> Response in
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest)
        }

        guard let device = await DeviceDiscovery.shared.getDevice(id: id) else {
            throw Abort(.notFound)
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(device)
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: data)
        )
    }

    // Refresh device discovery
    app.post("devices", "refresh") { req async -> Response in
        await DeviceDiscovery.shared.refreshDevices()
        return Response(status: .ok, body: .init(string: #"{"status":"refreshing"}"#))
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

    // CORS preflight for all routes
    app.on(.OPTIONS, "**") { req -> Response in
        var headers = HTTPHeaders()
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
        headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Range")
        return Response(status: .ok, headers: headers)
    }
}
