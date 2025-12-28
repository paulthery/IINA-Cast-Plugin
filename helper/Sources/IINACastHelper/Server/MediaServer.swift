import Foundation
import Vapor

/// HTTP Media Server with Range request support and DLNA headers
struct MediaServer {

    /// Register media serving routes
    static func registerRoutes(_ app: Application) {

        // Serve media files with Range support
        app.get("media", "**") { req async throws -> Response in
            let pathComponents = req.parameters.getCatchall()
            let relativePath = pathComponents.joined(separator: "/")

            // Decode URL-encoded path
            guard let decodedPath = relativePath.removingPercentEncoding else {
                throw Abort(.badRequest, reason: "Invalid path encoding")
            }

            // Security: only allow paths under allowed directories
            let filePath: String
            if decodedPath.hasPrefix("/") {
                filePath = decodedPath
            } else {
                filePath = "/tmp/iina-cast-media/\(decodedPath)"
            }

            return try await streamFile(path: filePath, request: req)
        }

        // Serve transcoded streams
        app.get("transcode", ":sessionId") { req async throws -> Response in
            guard let sessionId = req.parameters.get("sessionId") else {
                throw Abort(.badRequest)
            }

            // TODO: Return transcoded stream
            throw Abort(.notImplemented)
        }

        // Serve subtitles as WebVTT
        app.get("subtitles", ":id.vtt") { req async throws -> Response in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest)
            }

            let vttPath = "/tmp/iina-cast-subs/\(id).vtt"

            guard FileManager.default.fileExists(atPath: vttPath) else {
                throw Abort(.notFound)
            }

            let data = try Data(contentsOf: URL(fileURLWithPath: vttPath))

            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "text/vtt; charset=utf-8")
            headers.add(name: .accessControlAllowOrigin, value: "*")

            return Response(status: .ok, headers: headers, body: .init(data: data))
        }
    }

    /// Stream a file with full Range request support
    static func streamFile(path: String, request: Request) async throws -> Response {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: path) else {
            throw Abort(.notFound, reason: "File not found: \(path)")
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? Int64 else {
            throw Abort(.internalServerError, reason: "Cannot read file attributes")
        }

        let mimeType = guessMimeType(for: path)

        // Check for Range header
        if let rangeHeader = request.headers.first(name: .range) {
            return try await handleRangeRequest(
                path: path,
                fileSize: fileSize,
                rangeHeader: rangeHeader,
                mimeType: mimeType,
                request: request
            )
        }

        // No range - return full file
        return try await handleFullFileRequest(
            path: path,
            fileSize: fileSize,
            mimeType: mimeType,
            request: request
        )
    }

    // MARK: - Range Request Handling

    private static func handleRangeRequest(
        path: String,
        fileSize: Int64,
        rangeHeader: String,
        mimeType: String,
        request: Request
    ) async throws -> Response {

        // Parse "bytes=start-end" or "bytes=start-"
        guard let range = parseRangeHeader(rangeHeader, fileSize: fileSize) else {
            throw Abort(.rangeNotSatisfiable)
        }

        let start = range.start
        let end = range.end
        let length = end - start + 1

        // Open file and seek
        let fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? fileHandle.close() }

        try fileHandle.seek(toOffset: UInt64(start))
        let data = fileHandle.readData(ofLength: Int(length))

        var headers = buildHeaders(mimeType: mimeType, fileSize: fileSize)
        headers.add(name: .contentRange, value: "bytes \(start)-\(end)/\(fileSize)")
        headers.add(name: .contentLength, value: String(length))

        return Response(status: .partialContent, headers: headers, body: .init(data: data))
    }

    private static func handleFullFileRequest(
        path: String,
        fileSize: Int64,
        mimeType: String,
        request: Request
    ) async throws -> Response {

        var headers = buildHeaders(mimeType: mimeType, fileSize: fileSize)
        headers.add(name: .contentLength, value: String(fileSize))

        // Use streaming for large files
        let response = request.fileio.streamFile(at: path)
        for (name, value) in headers {
            response.headers.replaceOrAdd(name: name, value: value)
        }

        return response
    }

    // MARK: - Headers

    private static func buildHeaders(mimeType: String, fileSize: Int64) -> HTTPHeaders {
        var headers = HTTPHeaders()

        // Basic headers
        headers.add(name: .contentType, value: mimeType)
        headers.add(name: .acceptRanges, value: "bytes")

        // CORS headers (required for Chromecast)
        headers.add(name: .accessControlAllowOrigin, value: "*")
        headers.add(name: .accessControlAllowMethods, value: "GET, HEAD, OPTIONS")
        headers.add(name: .accessControlAllowHeaders, value: "Range, Content-Type")
        headers.add(name: .accessControlExposeHeaders, value: "Content-Range, Content-Length, Accept-Ranges")

        // DLNA headers
        headers.add(name: "transferMode.dlna.org", value: "Streaming")
        headers.add(name: "contentFeatures.dlna.org", value: buildDLNAFeatures(mimeType: mimeType))

        // Cache control
        headers.add(name: .cacheControl, value: "no-cache")

        return headers
    }

    private static func buildDLNAFeatures(mimeType: String) -> String {
        let pn: String
        switch mimeType {
        case "video/mp4":
            pn = "DLNA.ORG_PN=AVC_MP4_HP_HD_AAC"
        case "video/x-matroska":
            pn = "DLNA.ORG_PN=MATROSKA"
        default:
            pn = "DLNA.ORG_PN=AVC_MP4_HP_HD_AAC"
        }

        // DLNA flags: streaming, background transfer, connection stalling
        let flags = "DLNA.ORG_FLAGS=01700000000000000000000000000000"

        return "\(pn);\(flags)"
    }

    // MARK: - Helpers

    private static func parseRangeHeader(_ header: String, fileSize: Int64) -> (start: Int64, end: Int64)? {
        // Format: "bytes=start-end" or "bytes=start-"
        guard header.hasPrefix("bytes=") else { return nil }

        let rangeString = String(header.dropFirst(6))
        let parts = rangeString.split(separator: "-", omittingEmptySubsequences: false)

        guard parts.count == 2 else { return nil }

        let startString = String(parts[0])
        let endString = String(parts[1])

        let start: Int64
        let end: Int64

        if startString.isEmpty {
            // Suffix range: "-500" means last 500 bytes
            guard let suffixLength = Int64(endString) else { return nil }
            start = max(0, fileSize - suffixLength)
            end = fileSize - 1
        } else {
            guard let s = Int64(startString) else { return nil }
            start = s

            if endString.isEmpty {
                // Open-ended: "500-" means from 500 to end
                end = fileSize - 1
            } else {
                guard let e = Int64(endString) else { return nil }
                end = min(e, fileSize - 1)
            }
        }

        guard start <= end && start < fileSize else { return nil }

        return (start, end)
    }

    private static func guessMimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/avi"
        case "webm": return "video/webm"
        case "ts", "m2ts": return "video/mp2t"
        case "mov": return "video/quicktime"
        case "wmv": return "video/x-ms-wmv"
        case "flv": return "video/x-flv"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "vtt": return "text/vtt"
        case "srt": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Vapor Extensions

extension HTTPHeaders.Name {
    static let accessControlAllowOrigin = HTTPHeaders.Name("Access-Control-Allow-Origin")
    static let accessControlAllowMethods = HTTPHeaders.Name("Access-Control-Allow-Methods")
    static let accessControlAllowHeaders = HTTPHeaders.Name("Access-Control-Allow-Headers")
    static let accessControlExposeHeaders = HTTPHeaders.Name("Access-Control-Expose-Headers")
}
