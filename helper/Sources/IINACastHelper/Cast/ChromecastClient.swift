import Foundation
import NIO
import NIOSSL

/// CASTV2 Protocol Client for Chromecast devices
/// Protocol: TLS over TCP on port 8009
/// Message format: 4-byte length prefix + Protobuf CastMessage
actor ChromecastClient {
    private let host: String
    private let port: Int

    private var channel: Channel?
    private var eventLoopGroup: EventLoopGroup?

    private var transportId: String?
    private var sessionId: String?
    private var mediaSessionId: Int?
    private var requestId: Int = 0

    // Namespaces
    private let nsConnection = "urn:x-cast:com.google.cast.tp.connection"
    private let nsHeartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    private let nsReceiver = "urn:x-cast:com.google.cast.receiver"
    private let nsMedia = "urn:x-cast:com.google.cast.media"

    // Default Media Receiver App ID
    private let defaultMediaReceiverAppId = "CC1AD845"

    private var heartbeatTask: Task<Void, Never>?
    private var messageHandler: ((CastMessage) -> Void)?

    init(host: String, port: Int = 8009) {
        self.host = host
        self.port = port
    }

    // MARK: - Connection

    func connect() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        eventLoopGroup = group

        // Configure TLS (Chromecast uses self-signed certs)
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none

        let sslContext = try NIOSSLContext(configuration: tlsConfig)

        // Create a handler that will call back to us
        let handler = ChromecastChannelHandler { [weak self] message in
            Task {
                await self?.processMessage(message)
            }
        }

        let hostCopy = self.host
        let portCopy = self.port

        // Build pipeline handlers
        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: hostCopy)
        let frameDecoder = MessageFrameDecoder()
        let frameEncoder = MessageFrameEncoder()

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { (ch: Channel) in
                ch.pipeline.addHandler(sslHandler).flatMap {
                    ch.pipeline.addHandler(frameDecoder)
                }.flatMap {
                    ch.pipeline.addHandler(frameEncoder)
                }.flatMap {
                    ch.pipeline.addHandler(handler)
                }
            }

        channel = try await bootstrap.connect(host: hostCopy, port: portCopy).get()
        print("Connected to Chromecast at \(host):\(port)")

        // Send initial connection message
        try await sendConnect(destinationId: "receiver-0")

        // Start heartbeat
        startHeartbeat()
    }

    func disconnect() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil

        if let channel = channel {
            try? await channel.close()
        }
        self.channel = nil

        if let group = eventLoopGroup {
            try? await group.shutdownGracefully()
        }
        eventLoopGroup = nil
    }

    // MARK: - Receiver Control

    func launchDefaultMediaReceiver() async throws {
        try await launchApp(appId: defaultMediaReceiverAppId)
    }

    func launchApp(appId: String) async throws {
        let message: [String: Any] = [
            "type": "LAUNCH",
            "appId": appId,
            "requestId": nextRequestId()
        ]

        try await sendMessage(namespace: nsReceiver, destinationId: "receiver-0", payload: message)

        // Wait for RECEIVER_STATUS response with the app session
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    // MARK: - Media Control

    func loadMedia(url: String, contentType: String, startPosition: Double = 0) async throws {
        guard let transportId = transportId else {
            throw CastError.chromecastError("No active session")
        }

        // Connect to the media session
        try await sendConnect(destinationId: transportId)

        let media: [String: Any] = [
            "contentId": url,
            "contentType": contentType,
            "streamType": "BUFFERED"
        ]

        let message: [String: Any] = [
            "type": "LOAD",
            "requestId": nextRequestId(),
            "media": media,
            "autoplay": true,
            "currentTime": startPosition
        ]

        try await sendMessage(namespace: nsMedia, destinationId: transportId, payload: message)
    }

    func play() async throws {
        try await sendMediaCommand("PLAY")
    }

    func pause() async throws {
        try await sendMediaCommand("PAUSE")
    }

    func seek(to position: Double) async throws {
        guard let transportId = transportId, let mediaSessionId = mediaSessionId else {
            throw CastError.chromecastError("No active media session")
        }

        let message: [String: Any] = [
            "type": "SEEK",
            "requestId": nextRequestId(),
            "mediaSessionId": mediaSessionId,
            "currentTime": position
        ]

        try await sendMessage(namespace: nsMedia, destinationId: transportId, payload: message)
    }

    func stop() async throws {
        try await sendMediaCommand("STOP")
    }

    func setVolume(_ level: Double) async throws {
        let message: [String: Any] = [
            "type": "SET_VOLUME",
            "requestId": nextRequestId(),
            "volume": ["level": level]
        ]

        try await sendMessage(namespace: nsReceiver, destinationId: "receiver-0", payload: message)
    }

    // MARK: - Internal

    private func sendMediaCommand(_ type: String) async throws {
        guard let transportId = transportId, let mediaSessionId = mediaSessionId else {
            throw CastError.chromecastError("No active media session")
        }

        let message: [String: Any] = [
            "type": type,
            "requestId": nextRequestId(),
            "mediaSessionId": mediaSessionId
        ]

        try await sendMessage(namespace: nsMedia, destinationId: transportId, payload: message)
    }

    private func sendConnect(destinationId: String) async throws {
        let message: [String: Any] = [
            "type": "CONNECT",
            "origin": [String: Any]()
        ]

        try await sendMessage(namespace: nsConnection, destinationId: destinationId, payload: message)
    }

    private func sendMessage(namespace: String, destinationId: String, payload: [String: Any]) async throws {
        guard let channel = channel else {
            throw CastError.connectionFailed
        }

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        let castMessage = CastMessage(
            sourceId: "sender-0",
            destinationId: destinationId,
            namespace: namespace,
            payloadUtf8: jsonString
        )

        let data = castMessage.serialize()
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        try await channel.writeAndFlush(buffer)
    }

    private func startHeartbeat() {
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds

                let message: [String: Any] = ["type": "PING"]
                try? await sendMessage(namespace: nsHeartbeat, destinationId: "receiver-0", payload: message)
            }
        }
    }

    private func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }

    private func processMessage(_ message: CastMessage) {
        guard let data = message.payloadUtf8.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let type = json["type"] as? String ?? ""

        switch type {
        case "RECEIVER_STATUS":
            if let status = json["status"] as? [String: Any],
               let applications = status["applications"] as? [[String: Any]],
               let app = applications.first {
                transportId = app["transportId"] as? String
                sessionId = app["sessionId"] as? String
            }

        case "MEDIA_STATUS":
            if let statuses = json["status"] as? [[String: Any]],
               let status = statuses.first {
                mediaSessionId = status["mediaSessionId"] as? Int
            }

        case "PONG":
            // Heartbeat response
            break

        default:
            print("Chromecast message: \(type)")
        }
    }
}

// MARK: - Cast Message

struct CastMessage: Sendable {
    let sourceId: String
    let destinationId: String
    let namespace: String
    let payloadUtf8: String

    func serialize() -> [UInt8] {
        // Simplified protobuf serialization for CASTV2
        // Field 1: protocol_version (varint) = 0
        // Field 2: source_id (string)
        // Field 3: destination_id (string)
        // Field 4: namespace (string)
        // Field 5: payload_type (varint) = 0 (string)
        // Field 6: payload_utf8 (string)

        var data = Data()

        // Protocol version = 0
        data.append(contentsOf: [0x08, 0x00])

        // Source ID (field 2, wire type 2)
        data.append(0x12)
        data.append(contentsOf: encodeVarint(sourceId.utf8.count))
        data.append(contentsOf: sourceId.utf8)

        // Destination ID (field 3, wire type 2)
        data.append(0x1a)
        data.append(contentsOf: encodeVarint(destinationId.utf8.count))
        data.append(contentsOf: destinationId.utf8)

        // Namespace (field 4, wire type 2)
        data.append(0x22)
        data.append(contentsOf: encodeVarint(namespace.utf8.count))
        data.append(contentsOf: namespace.utf8)

        // Payload type = 0 (string) (field 5, wire type 0)
        data.append(0x28)
        data.append(0x00)

        // Payload UTF8 (field 6, wire type 2)
        data.append(0x32)
        data.append(contentsOf: encodeVarint(payloadUtf8.utf8.count))
        data.append(contentsOf: payloadUtf8.utf8)

        // Prepend 4-byte big-endian length
        var result = Data()
        let length = UInt32(data.count)
        result.append(UInt8((length >> 24) & 0xFF))
        result.append(UInt8((length >> 16) & 0xFF))
        result.append(UInt8((length >> 8) & 0xFF))
        result.append(UInt8(length & 0xFF))
        result.append(data)

        return Array(result)
    }

    private func encodeVarint(_ value: Int) -> [UInt8] {
        var result: [UInt8] = []
        var v = value
        while v > 127 {
            result.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        result.append(UInt8(v))
        return result
    }

    static func parse(from data: Data) -> CastMessage? {
        var sourceId = ""
        var destinationId = ""
        var namespace = ""
        var payloadUtf8 = ""

        var index = 0
        while index < data.count {
            guard index < data.count else { break }
            let fieldTag = data[index]
            index += 1

            let fieldNumber = fieldTag >> 3
            let wireType = fieldTag & 0x07

            switch wireType {
            case 0: // Varint
                while index < data.count && data[index] & 0x80 != 0 {
                    index += 1
                }
                if index < data.count { index += 1 }

            case 2: // Length-delimited
                var length = 0
                var shift = 0
                while index < data.count {
                    let byte = data[index]
                    index += 1
                    length |= Int(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { break }
                    shift += 7
                }

                if index + length <= data.count {
                    let stringData = data[index..<(index + length)]
                    let string = String(data: stringData, encoding: .utf8) ?? ""

                    switch fieldNumber {
                    case 2: sourceId = string
                    case 3: destinationId = string
                    case 4: namespace = string
                    case 6: payloadUtf8 = string
                    default: break
                    }
                }
                index += length

            default:
                break
            }
        }

        return CastMessage(
            sourceId: sourceId,
            destinationId: destinationId,
            namespace: namespace,
            payloadUtf8: payloadUtf8
        )
    }
}

// MARK: - NIO Handlers

/// Decodes length-prefixed messages (4-byte big-endian length + payload)
final class MessageFrameDecoder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private var accumulated = Data()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            accumulated.append(contentsOf: bytes)
        }

        // Process complete frames
        while accumulated.count >= 4 {
            let length = Int(accumulated[0]) << 24 | Int(accumulated[1]) << 16 | Int(accumulated[2]) << 8 | Int(accumulated[3])

            guard accumulated.count >= 4 + length else {
                break // Wait for more data
            }

            // Extract frame
            let frameData = accumulated[4..<(4 + length)]
            accumulated.removeFirst(4 + length)

            // Forward frame
            var frameBuffer = context.channel.allocator.buffer(capacity: frameData.count)
            frameBuffer.writeBytes(frameData)
            context.fireChannelRead(wrapInboundOut(frameBuffer))
        }
    }
}

/// Encodes messages - data is already length-prefixed by CastMessage.serialize()
final class MessageFrameEncoder: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        // Data already has length prefix from CastMessage.serialize()
        context.write(data, promise: promise)
    }
}

/// Handles incoming Chromecast messages
final class ChromecastChannelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let onMessage: (CastMessage) -> Void

    init(onMessage: @escaping (CastMessage) -> Void) {
        self.onMessage = onMessage
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }

        if let message = CastMessage.parse(from: Data(bytes)) {
            onMessage(message)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("Chromecast connection error: \(error)")
        context.close(promise: nil)
    }
}
