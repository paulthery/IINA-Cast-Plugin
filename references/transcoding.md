# Transcoding Reference

Complete FFmpeg transcoding guide for casting high-bitrate content including Blu-ray remux, HDR, and Dolby Vision.

---

## VideoToolbox Hardware Acceleration

macOS provides hardware encoding/decoding via VideoToolbox framework. FFmpeg supports it natively.

### Available Hardware Codecs

| Encoder | Codec | Apple Silicon | Intel |
|---------|-------|---------------|-------|
| `h264_videotoolbox` | H.264/AVC | ✅ Excellent | ✅ Good |
| `hevc_videotoolbox` | H.265/HEVC | ✅ Excellent | ✅ Good (6th gen+) |
| `prores_videotoolbox` | ProRes | ✅ | ❌ |

| Decoder | Usage |
|---------|-------|
| `-hwaccel videotoolbox` | HW decode any supported format |
| `-hwaccel auto` | Auto-select best available |

### Performance Comparison

| Task | Software | VideoToolbox | Speedup |
|------|----------|--------------|---------|
| 1080p H.264 encode | 30 fps | 180+ fps | ~6x |
| 4K HEVC encode | 8 fps | 60+ fps | ~7x |
| 4K HEVC decode | 24 fps | 120+ fps | ~5x |

---

## Media Probing

### Get Complete Media Info

```bash
ffprobe -v quiet -print_format json -show_format -show_streams input.mkv
```

### Swift Implementation

```swift
import Foundation

struct MediaInfo: Codable {
    let format: FormatInfo
    let streams: [StreamInfo]
}

struct FormatInfo: Codable {
    let filename: String
    let formatName: String
    let duration: String
    let size: String
    let bitRate: String
    
    enum CodingKeys: String, CodingKey {
        case filename
        case formatName = "format_name"
        case duration
        case size
        case bitRate = "bit_rate"
    }
}

struct StreamInfo: Codable {
    let index: Int
    let codecType: String
    let codecName: String
    let profile: String?
    let width: Int?
    let height: Int?
    let pixFmt: String?
    let colorSpace: String?
    let colorTransfer: String?
    let colorPrimaries: String?
    let channels: Int?
    let sampleRate: String?
    let bitRate: String?
    
    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case codecName = "codec_name"
        case profile
        case width
        case height
        case pixFmt = "pix_fmt"
        case colorSpace = "color_space"
        case colorTransfer = "color_transfer"
        case colorPrimaries = "color_primaries"
        case channels
        case sampleRate = "sample_rate"
        case bitRate = "bit_rate"
    }
    
    var isHDR: Bool {
        colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67"
    }
    
    var isDolbyVision: Bool {
        // Check for DV side data or specific profile
        profile?.contains("dvhe") == true || profile?.contains("dvav") == true
    }
}

func probeMedia(path: String) async throws -> MediaInfo {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffprobe")
    process.arguments = [
        "-v", "quiet",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        path
    ]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    
    try process.run()
    process.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return try JSONDecoder().decode(MediaInfo.self, from: data)
}
```

### HDR Detection

```swift
func detectHDRType(stream: StreamInfo) -> HDRType {
    guard stream.codecType == "video" else { return .sdr }
    
    // Check color transfer characteristic
    switch stream.colorTransfer {
    case "smpte2084":
        // Could be HDR10, HDR10+, or Dolby Vision
        if stream.isDolbyVision {
            return .dolbyVision
        }
        // Check for HDR10+ dynamic metadata (requires deeper probe)
        return .hdr10
        
    case "arib-std-b67":
        return .hlg
        
    default:
        return .sdr
    }
}

enum HDRType {
    case sdr
    case hdr10
    case hdr10Plus
    case dolbyVision
    case hlg
}
```

---

## Transcoding Profiles

### Profile Selection Logic

```swift
enum TranscodeAction {
    case directPlay                      // No processing
    case remux(container: String)        // Container change only
    case transcodeAudio(codec: String)   // Audio only
    case transcodeVideo(profile: VideoProfile)  // Video only
    case transcodeFull(profile: FullProfile)    // Everything
}

struct VideoProfile {
    let codec: String           // "h264_videotoolbox"
    let profile: String         // "high"
    let level: String           // "4.2"
    let bitrate: Int           // kbps
    let maxrate: Int           // kbps
    let bufsize: Int           // kbps
    let resolution: Resolution?
    let hdrHandling: HDRHandling
}

enum HDRHandling {
    case preserve              // Keep HDR (if device supports)
    case tonemapToSDR         // Convert to SDR
}

struct Resolution {
    let width: Int
    let height: Int
}

func selectTranscodeAction(
    media: MediaInfo,
    device: CastDevice,
    userPrefs: UserPreferences
) -> TranscodeAction {
    
    let videoStream = media.streams.first { $0.codecType == "video" }!
    let audioStream = media.streams.first { $0.codecType == "audio" }!
    
    // 1. Container check
    let containerOK: Bool
    switch device.type {
    case .chromecast:
        containerOK = media.format.formatName == "mov,mp4,m4a,3gp,3g2,mj2"
    case .dlna:
        containerOK = true  // Most containers OK
    }
    
    // 2. Video codec check
    let videoCodecOK = device.capabilities.codecs.contains(videoStream.codecName)
    
    // 3. HDR check
    let hdrOK: Bool
    if videoStream.isHDR {
        hdrOK = device.capabilities.hdr
        // Note: Dolby Vision almost never supported on cast devices
    } else {
        hdrOK = true
    }
    
    // 4. Audio codec check
    let audioCodecOK = device.capabilities.audioCodecs.contains(audioStream.codecName)
    
    // 5. Bitrate check
    let bitrateOK = (Int(media.format.bitRate) ?? 0) / 1000 < device.maxBitrate
    
    // Decision tree
    if containerOK && videoCodecOK && hdrOK && audioCodecOK && bitrateOK {
        return .directPlay
    }
    
    if !containerOK && videoCodecOK && hdrOK && audioCodecOK {
        return .remux(container: "mp4")
    }
    
    if containerOK && videoCodecOK && hdrOK && !audioCodecOK {
        return .transcodeAudio(codec: userPrefs.audioFallback)
    }
    
    // Full transcode needed
    return .transcodeFull(profile: buildProfile(media, device, userPrefs))
}
```

### FFmpeg Command Builder

```swift
func buildFFmpegCommand(
    input: String,
    output: String,  // "pipe:1" for streaming
    action: TranscodeAction
) -> [String] {
    
    var args: [String] = []
    
    // Input with hardware decode
    args += ["-hwaccel", "videotoolbox"]
    args += ["-i", input]
    
    switch action {
    case .directPlay:
        fatalError("Direct play doesn't need FFmpeg")
        
    case .remux(let container):
        args += ["-c:v", "copy"]
        args += ["-c:a", "copy"]
        args += ["-f", container]
        if container == "mp4" {
            args += ["-movflags", "frag_keyframe+empty_moov+faststart"]
        }
        
    case .transcodeAudio(let codec):
        args += ["-c:v", "copy"]
        args += buildAudioArgs(codec: codec)
        args += ["-f", "mp4"]
        args += ["-movflags", "frag_keyframe+empty_moov"]
        
    case .transcodeVideo(let profile):
        args += buildVideoArgs(profile: profile)
        args += ["-c:a", "copy"]
        args += ["-f", "mp4"]
        args += ["-movflags", "frag_keyframe+empty_moov"]
        
    case .transcodeFull(let profile):
        args += buildVideoArgs(profile: profile.video)
        args += buildAudioArgs(codec: profile.audioCodec)
        args += ["-f", "mp4"]
        args += ["-movflags", "frag_keyframe+empty_moov"]
    }
    
    args += [output]
    return args
}

func buildVideoArgs(profile: VideoProfile) -> [String] {
    var args: [String] = []
    
    args += ["-c:v", profile.codec]
    args += ["-profile:v", profile.profile]
    args += ["-level", profile.level]
    args += ["-b:v", "\(profile.bitrate)k"]
    args += ["-maxrate", "\(profile.maxrate)k"]
    args += ["-bufsize", "\(profile.bufsize)k"]
    
    if let res = profile.resolution {
        args += ["-vf", "scale=\(res.width):\(res.height)"]
    }
    
    // HDR handling
    switch profile.hdrHandling {
    case .preserve:
        // Copy color metadata
        args += ["-color_primaries", "bt2020"]
        args += ["-color_trc", "smpte2084"]
        args += ["-colorspace", "bt2020nc"]
        
    case .tonemapToSDR:
        // Tonemap filter
        let vf = profile.resolution != nil
            ? "scale=\(profile.resolution!.width):\(profile.resolution!.height),zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709,format=yuv420p"
            : "zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709,format=yuv420p"
        args += ["-vf", vf]
    }
    
    return args
}

func buildAudioArgs(codec: String) -> [String] {
    switch codec {
    case "aac":
        return ["-c:a", "aac", "-b:a", "384k", "-ac", "6"]
    case "ac3":
        return ["-c:a", "ac3", "-b:a", "448k", "-ac", "6"]
    case "eac3":
        return ["-c:a", "eac3", "-b:a", "640k", "-ac", "6"]
    default:
        return ["-c:a", "aac", "-b:a", "256k", "-ac", "2"]
    }
}
```

---

## Preset Profiles

### Chromecast Universal (1080p)

```bash
ffmpeg -hwaccel videotoolbox -i input.mkv \
  -c:v h264_videotoolbox \
  -profile:v high -level 4.2 \
  -b:v 8M -maxrate 12M -bufsize 24M \
  -c:a aac -b:a 256k -ac 2 \
  -f mp4 -movflags frag_keyframe+empty_moov \
  pipe:1
```

### Chromecast Ultra 4K HDR

```bash
ffmpeg -hwaccel videotoolbox -i input.mkv \
  -c:v hevc_videotoolbox \
  -profile:v main10 \
  -b:v 25M -maxrate 40M -bufsize 80M \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -c:a eac3 -b:a 640k -ac 6 \
  -f mp4 -movflags frag_keyframe+empty_moov \
  pipe:1
```

### DLNA Maximum Quality

```bash
ffmpeg -hwaccel videotoolbox -i input.mkv \
  -c:v hevc_videotoolbox \
  -profile:v main10 \
  -b:v 40M -maxrate 60M -bufsize 120M \
  -c:a aac -b:a 384k -ac 6 \
  -f matroska \
  pipe:1
```

### Audio-Only Transcode (DTS → AAC)

```bash
ffmpeg -i input.mkv \
  -c:v copy \
  -c:a aac -b:a 384k -ac 6 \
  -f mp4 -movflags frag_keyframe+empty_moov \
  pipe:1
```

### Remux MKV → MP4

```bash
ffmpeg -i input.mkv \
  -c:v copy -c:a copy \
  -f mp4 -movflags frag_keyframe+empty_moov+faststart \
  pipe:1
```

### HDR → SDR Tonemap

```bash
ffmpeg -hwaccel videotoolbox -i input.mkv \
  -vf "zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709,format=yuv420p" \
  -c:v h264_videotoolbox \
  -profile:v high -level 4.2 \
  -b:v 15M -maxrate 20M \
  -c:a aac -b:a 256k \
  -f mp4 -movflags frag_keyframe+empty_moov \
  pipe:1
```

---

## Subtitle Handling

### Extract to WebVTT

```bash
# From internal track (index 0)
ffmpeg -i input.mkv -map 0:s:0 -c:s webvtt output.vtt

# From SRT file
ffmpeg -i input.srt output.vtt

# From ASS (loses styling)
ffmpeg -i input.ass -c:s webvtt output.vtt
```

### Burn-in Subtitles

```bash
# Internal SRT/ASS track
ffmpeg -i input.mkv \
  -vf "subtitles=input.mkv:si=0" \
  -c:v h264_videotoolbox \
  -c:a copy \
  output.mp4

# External SRT
ffmpeg -i input.mkv \
  -vf "subtitles=subs.srt:force_style='FontSize=24,PrimaryColour=&Hffffff&'" \
  -c:v h264_videotoolbox \
  -c:a copy \
  output.mp4

# External ASS with full styling
ffmpeg -i input.mkv \
  -vf "ass=subs.ass" \
  -c:v h264_videotoolbox \
  -c:a copy \
  output.mp4
```

### PGS (Blu-ray) Subtitles

PGS (Presentation Graphic Stream) are bitmap subtitles. Options:

1. **Burn-in** (always works):
```bash
ffmpeg -i input.mkv \
  -filter_complex "[0:v][0:s:0]overlay[v]" \
  -map "[v]" -map 0:a \
  -c:v h264_videotoolbox \
  -c:a copy \
  output.mp4
```

2. **OCR to SRT** (requires Tesseract):
```bash
# Use PGSToSrt or SubtitleEdit for OCR conversion first
```

### Swift Subtitle Extraction

```swift
func extractSubtitles(input: String, trackIndex: Int, output: String) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
    process.arguments = [
        "-i", input,
        "-map", "0:s:\(trackIndex)",
        "-c:s", "webvtt",
        output
    ]
    
    try process.run()
    process.waitUntilExit()
    
    if process.terminationStatus != 0 {
        throw TranscodeError.subtitleExtractionFailed
    }
}
```

---

## Live Streaming Output

### Fragmented MP4 for HTTP Streaming

Key flags:
- `frag_keyframe` — Fragment at keyframes
- `empty_moov` — No initial moov atom (streamable immediately)
- `faststart` — Move moov to beginning (for files)

```swift
func startLiveTranscode(input: String, profile: TranscodeProfile) -> AsyncStream<Data> {
    AsyncStream { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        process.arguments = buildFFmpegCommand(
            input: input,
            output: "pipe:1",
            action: .transcodeFull(profile: profile)
        )
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        
        process.terminationHandler = { _ in
            continuation.finish()
        }
        
        try? process.run()
        
        continuation.onTermination = { _ in
            process.terminate()
        }
    }
}
```

---

## Bitrate Guidelines

### Video Bitrate by Resolution and Content

| Resolution | Film (24fps) | Animation | Action (60fps) | HDR Boost |
|------------|--------------|-----------|----------------|-----------|
| 720p | 4-6 Mbps | 2-4 Mbps | 6-8 Mbps | N/A |
| 1080p | 8-12 Mbps | 5-8 Mbps | 12-18 Mbps | +50% |
| 1440p | 15-20 Mbps | 10-15 Mbps | 20-30 Mbps | +50% |
| 2160p (4K) | 25-35 Mbps | 15-25 Mbps | 40-60 Mbps | +50% |

### Audio Bitrate

| Codec | Stereo | 5.1 | 7.1 |
|-------|--------|-----|-----|
| AAC | 128-192 kbps | 256-384 kbps | 384-512 kbps |
| AC3 | 192 kbps | 384-448 kbps | N/A |
| E-AC3 | 128-192 kbps | 384-640 kbps | 640-768 kbps |

---

## Adaptive Bitrate (Future)

Monitor cast device buffer and adjust:

```swift
class AdaptiveBitrate {
    private var currentBitrate: Int = 20_000  // kbps
    private let minBitrate = 2_000
    private let maxBitrate = 50_000
    
    func adjustForBufferLevel(_ percent: Int) {
        switch percent {
        case 0..<20:
            // Critical - drop significantly
            currentBitrate = max(minBitrate, currentBitrate * 60 / 100)
        case 20..<40:
            // Low - reduce
            currentBitrate = max(minBitrate, currentBitrate * 80 / 100)
        case 60..<80:
            // Good - can increase
            currentBitrate = min(maxBitrate, currentBitrate * 110 / 100)
        case 80...100:
            // Excellent - increase more
            currentBitrate = min(maxBitrate, currentBitrate * 120 / 100)
        default:
            break  // Stable, no change
        }
    }
}
```

---

## Common Issues and Solutions

### "moov atom not found"
**Cause**: MP4 not streamable (moov at end)
**Fix**: Add `-movflags +faststart` for files or use fragmented MP4 for streaming

### Hardware encoder session limit
**Cause**: VideoToolbox limits concurrent sessions (~3-4)
**Fix**: Limit concurrent transcodes, queue additional requests

### Audio/video sync drift
**Cause**: Variable frame rate or container timing issues
**Fix**: Add `-async 1` or `-vsync cfr` and explicitly set `-ar 48000`

### HDR washed out after transcode
**Cause**: Missing tonemap when converting HDR → SDR
**Fix**: Use zscale + tonemap filter chain

### Subtitle timing off
**Cause**: Different timebase between video and subtitles
**Fix**: Use `-copyts` flag or re-encode subtitles

### High CPU during "direct play"
**Cause**: Container remux still happening
**Fix**: Verify container compatibility, serve raw file if possible
