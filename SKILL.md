---
name: iina-cast-plugin
description: Build a professional casting plugin for IINA (macOS video player) with UPNP/DLNA and Chromecast support. Use when developing the IINA Cast Plugin project — covers hybrid architecture (JS plugin + Swift helper), device discovery (SSDP/mDNS), CASTV2 and SOAP protocols, transcoding pipeline with VideoToolbox, HDR/DV handling, and high-bitrate remux streaming. Inspired by Stremio V4's proven casting implementation.
---

# IINA Cast Plugin — Complete Development Guide

Build a native, professional-grade casting plugin for IINA with DLNA and Chromecast support, optimized for high-bitrate content (Blu-ray remux, HDR, Dolby Vision).

## Target Use Cases

| Content Type | Size | Best Path | Transcoding |
|--------------|------|-----------|-------------|
| Blu-ray Remux 4K HDR | 50-80 GB | DLNA Direct Play | None |
| Blu-ray Remux DV | 50-80 GB | DLNA (HDR10 fallback) | None |
| Web streams (H.264) | Variable | Chromecast Direct | None |
| MKV to Chromecast | Any | Remux to MP4 | Container only |
| Incompatible codec | Any | Full transcode | VideoToolbox |

## Architecture Overview

Inspired by **Stremio V4's proven architecture**: separation between UI (plugin), server (helper), and protocol handlers.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  IINA.app                                                                   │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  iina-cast.iinaplugin (JavaScript)                                    │  │
│  │  ├── main.js      → Per-player: controls, sync, UI                   │  │
│  │  ├── global.js    → Lifecycle: helper spawn, health check            │  │
│  │  └── ui/          → Sidebar (device picker), Overlay (cast badge)    │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    │                                         │
│                        HTTP REST (localhost:9876)                           │
│                                    │                                         │
└────────────────────────────────────┼─────────────────────────────────────────┘
                                     │
┌────────────────────────────────────▼─────────────────────────────────────────┐
│  IINACastHelper (Swift Binary)                                               │
│  ├── REST API Server (Vapor)                                                │
│  ├── Discovery/                                                              │
│  │   ├── ChromecastDiscovery  → NWBrowser + mDNS (_googlecast._tcp)        │
│  │   └── DLNADiscovery        → SSDP multicast + device description        │
│  ├── Protocols/                                                              │
│  │   ├── CASTV2Client         → TLS:8009, Protobuf, Default Media Receiver │
│  │   └── DLNAClient           → SOAP/HTTP, AVTransport, RenderingControl   │
│  ├── MediaServer/                                                            │
│  │   ├── HTTPServer           → Range requests, CORS, DLNA headers         │
│  │   └── ProxyServer          → Stream relay for remote URLs               │
│  └── Transcode/                                                              │
│      ├── ProbeService         → FFprobe media analysis                      │
│      ├── TranscodeManager     → FFmpeg + VideoToolbox HW accel             │
│      └── SubtitleConverter    → SRT/ASS → WebVTT, burn-in                  │
└──────────────────────────────────────────────────────────────────────────────┘
                     │                                    │
    ┌────────────────┴────────────┐    ┌─────────────────┴──────────────────┐
    ▼                             ▼    ▼                                    ▼
┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────────┐
│  Chromecast Ultra   │  │  Samsung TV (DLNA)  │  │  Other DLNA Renderers   │
│  TLS:8009 (CASTV2)  │  │  SOAP (AVTransport) │  │  LG, Sony, etc.         │
│  HTTP: media pull   │  │  HTTP: media pull   │  │  HTTP: media pull       │
└─────────────────────┘  └─────────────────────┘  └─────────────────────────┘
```

## Project Structure

```
IINA-Cast-Plugin/
├── SKILL.md
├── README.md
├── iina-cast.iinaplugin/
│   ├── Info.json
│   ├── main.js
│   ├── global.js
│   ├── lib/
│   │   ├── cast-api.js          # Helper communication
│   │   ├── state-sync.js        # Position/state synchronization
│   │   └── format-utils.js      # Time formatting, bitrate display
│   ├── ui/
│   │   ├── sidebar.html         # Device picker + settings
│   │   └── overlay.html         # Cast indicator + mini controls
│   └── preferences.html         # Plugin preferences page
├── helper/
│   ├── Package.swift
│   └── Sources/IINACastHelper/
│       ├── main.swift
│       ├── App/
│       │   ├── Routes.swift
│       │   └── Config.swift
│       ├── Discovery/
│       │   ├── DeviceManager.swift
│       │   ├── ChromecastDiscovery.swift
│       │   └── DLNADiscovery.swift
│       ├── Protocols/
│       │   ├── CASTV2/
│       │   │   ├── CASTV2Client.swift
│       │   │   ├── CASTV2Channel.swift
│       │   │   └── MediaChannel.swift
│       │   └── DLNA/
│       │       ├── DLNAClient.swift
│       │       ├── SOAPClient.swift
│       │       └── DIDLBuilder.swift
│       ├── Server/
│       │   ├── MediaServer.swift
│       │   ├── RangeRequestHandler.swift
│       │   └── StreamProxy.swift
│       ├── Transcode/
│       │   ├── MediaProbe.swift
│       │   ├── TranscodeManager.swift
│       │   ├── TranscodeProfile.swift
│       │   └── SubtitleConverter.swift
│       └── Models/
│           ├── CastDevice.swift
│           ├── MediaInfo.swift
│           └── CastSession.swift
└── resources/
    └── ffmpeg/                   # Bundled FFmpeg binaries (optional)
```

## Plugin Manifest

```json
{
  "name": "IINA Cast",
  "identifier": "io.github.iina-cast",
  "version": "1.0.0",
  "minIINAVersion": "1.4.0",
  "author": {
    "name": "Your Name",
    "url": "https://github.com/yourusername/IINA-Cast-Plugin"
  },
  "description": "Cast to Chromecast and DLNA devices with full quality control",
  "entry": "main.js",
  "globalEntry": "global.js",
  "preferencePage": "preferences.html",
  "sidebarTab": { "name": "Cast" },
  "permissions": [
    "show-osd",
    "video-overlay",
    "network-request",
    "file-system"
  ],
  "preferenceDefaults": {
    "autoDiscovery": true,
    "preferredProtocol": "auto",
    "defaultMode": "direct",
    "transcodeBitrate": 20000,
    "transcodeResolution": "source",
    "audioFallback": "aac",
    "subtitleMode": "auto",
    "bufferDuration": 60,
    "prebufferEnabled": true,
    "helperPort": 9876
  }
}
```

## REST API Specification

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `GET /health` | GET | Health check |
| `GET /devices` | GET | List discovered devices |
| `GET /devices/:id` | GET | Device details + capabilities |
| `POST /cast/start` | POST | Start casting session |
| `POST /cast/stop` | POST | Stop casting |
| `GET /cast/status` | GET | Current cast status |
| `POST /cast/control` | POST | Playback control (play/pause/seek/volume) |
| `GET /media/probe` | GET | Probe media file/URL |
| `POST /media/transcode` | POST | Start transcode job |
| `GET /media/stream/:id` | GET | Stream media (Range support) |
| `GET /subtitles/:id.vtt` | GET | Serve WebVTT subtitles |

### Request/Response Models

```typescript
// Device
interface CastDevice {
  id: string;
  name: string;
  type: "chromecast" | "dlna";
  address: string;
  port: number;
  capabilities: {
    maxWidth: number;
    maxHeight: number;
    codecs: string[];        // ["h264", "hevc", "vp9"]
    hdr: boolean;
    dolbyVision: boolean;
    audioCodecs: string[];   // ["aac", "ac3", "eac3", "dts"]
    subtitleFormats: string[];
  };
  status: "idle" | "casting" | "busy";
}

// Cast Request
interface CastRequest {
  deviceId: string;
  mediaUrl: string;          // Local path or HTTP URL
  position?: number;         // Start position in seconds
  mode: "direct" | "remux" | "transcode";
  transcodeOptions?: {
    videoBitrate?: number;   // kbps
    resolution?: "source" | "2160p" | "1080p" | "720p";
    audioTrack?: number;
    audioCodec?: "source" | "aac" | "ac3";
  };
  subtitles?: {
    track?: number;          // Internal track index
    externalUrl?: string;    // External subtitle file
    mode: "sidecar" | "burnin" | "off";
  };
}

// Cast Status
interface CastStatus {
  active: boolean;
  device?: CastDevice;
  media?: {
    url: string;
    title: string;
    duration: number;
    position: number;
    state: "buffering" | "playing" | "paused" | "stopped" | "error";
    bufferPercent: number;
  };
  transcoding?: {
    active: boolean;
    progress: number;
    speed: string;
  };
}

// Control Command
interface ControlCommand {
  action: "play" | "pause" | "seek" | "volume" | "stop";
  value?: number;  // seek position or volume (0-100)
}
```

## Protocol Implementation Details

### Chromecast CASTV2

Connection flow:
1. **mDNS Discovery** → `_googlecast._tcp.local`
2. **TLS Connection** → port 8009, self-signed cert (ignore validation)
3. **Virtual Connection** → `urn:x-cast:com.google.cast.tp.connection`
4. **Heartbeat** → `urn:x-cast:com.google.cast.tp.heartbeat` (every 5s)
5. **Launch Receiver** → `urn:x-cast:com.google.cast.receiver` (App ID: `CC1AD845`)
6. **Media Control** → `urn:x-cast:com.google.cast.media`

Media load payload:
```json
{
  "type": "LOAD",
  "requestId": 1,
  "sessionId": "<session-id>",
  "media": {
    "contentId": "http://192.168.1.100:9877/media/stream/abc123",
    "contentType": "video/mp4",
    "streamType": "BUFFERED",
    "duration": 7200,
    "metadata": {
      "metadataType": 1,
      "title": "Movie Title"
    },
    "tracks": [{
      "trackId": 1,
      "type": "TEXT",
      "trackContentId": "http://192.168.1.100:9877/subtitles/abc123.vtt",
      "trackContentType": "text/vtt",
      "subtype": "SUBTITLES",
      "name": "French",
      "language": "fr"
    }]
  },
  "autoplay": true,
  "currentTime": 0
}
```

### DLNA/UPNP

Discovery flow:
1. **SSDP M-SEARCH** → UDP 239.255.255.250:1900
2. **Parse Response** → Get LOCATION header
3. **Fetch Device Description** → XML with services
4. **Find AVTransport** → Get controlURL

Control via SOAP:
```http
POST /AVTransport/control HTTP/1.1
Host: 192.168.1.50:52235
Content-Type: text/xml; charset="utf-8"
SOAPACTION: "urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"

<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <CurrentURI>http://192.168.1.100:9877/media/stream/abc123</CurrentURI>
      <CurrentURIMetaData>&lt;DIDL-Lite ...&gt;...&lt;/DIDL-Lite&gt;</CurrentURIMetaData>
    </u:SetAVTransportURI>
  </s:Body>
</s:Envelope>
```

## Media Server Requirements

### HTTP Headers for Cast Devices

```swift
// Essential headers for all cast devices
response.headers.add(name: "Accept-Ranges", value: "bytes")
response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
response.headers.add(name: "Access-Control-Allow-Methods", value: "GET, HEAD, OPTIONS")
response.headers.add(name: "Access-Control-Allow-Headers", value: "Range, Content-Type")
response.headers.add(name: "Content-Type", value: mimeType) // video/mp4, video/x-matroska

// DLNA-specific headers
response.headers.add(name: "transferMode.dlna.org", value: "Streaming")
response.headers.add(name: "contentFeatures.dlna.org", value: dlnaFeatures)
// Example: DLNA.ORG_PN=AVC_MP4_HP_HD_AAC;DLNA.ORG_FLAGS=01700000000000000000000000000000
```

### Range Request Handler

```swift
func handleRangeRequest(request: Request, fileSize: Int64) -> Response {
    guard let rangeHeader = request.headers.first(name: "Range") else {
        // No range = full file
        return streamFullFile()
    }
    
    // Parse "bytes=start-end"
    let (start, end) = parseRange(rangeHeader, fileSize: fileSize)
    let length = end - start + 1
    
    var headers = HTTPHeaders()
    headers.add(name: "Content-Range", value: "bytes \(start)-\(end)/\(fileSize)")
    headers.add(name: "Content-Length", value: String(length))
    headers.add(name: "Accept-Ranges", value: "bytes")
    
    return Response(
        status: .partialContent,  // 206
        headers: headers,
        body: .init(stream: fileStream(from: start, length: length))
    )
}
```

## Transcoding Profiles

### Profile Selection Logic

```swift
func selectProfile(media: MediaInfo, device: CastDevice, userPrefs: CastPreferences) -> TranscodeProfile {
    // 1. Check if direct play possible
    if canDirectPlay(media: media, device: device) {
        return .direct
    }
    
    // 2. Check if remux sufficient (container change only)
    if canRemux(media: media, device: device) {
        return .remux(container: device.preferredContainer)
    }
    
    // 3. Full transcode needed
    return .transcode(
        videoCodec: selectVideoCodec(device),
        videoBitrate: userPrefs.videoBitrate ?? calculateBitrate(media, device),
        audioCodec: selectAudioCodec(media, device),
        resolution: userPrefs.resolution ?? device.maxResolution
    )
}

func canDirectPlay(media: MediaInfo, device: CastDevice) -> Bool {
    // Container check
    let containerOK = device.type == .dlna || media.container == "mp4"
    
    // Video codec check
    let videoOK = device.capabilities.codecs.contains(media.videoCodec)
    
    // Audio codec check  
    let audioOK = device.capabilities.audioCodecs.contains(media.audioCodec)
    
    // Bitrate check (for network stability)
    let bitrateOK = media.bitrate < device.maxBitrate
    
    return containerOK && videoOK && audioOK && bitrateOK
}
```

### FFmpeg Commands

```bash
# Direct stream (no processing)
# Just serve the file via HTTP

# Remux MKV → MP4 (Chromecast)
ffmpeg -i input.mkv \
  -c:v copy -c:a copy \
  -movflags frag_keyframe+empty_moov+faststart \
  -f mp4 pipe:1

# Transcode HEVC → H.264 (Hardware accelerated)
ffmpeg -hwaccel videotoolbox -i input.mkv \
  -c:v h264_videotoolbox \
  -profile:v high -level 4.2 \
  -b:v 20M -maxrate 30M -bufsize 60M \
  -c:a aac -b:a 384k -ac 6 \
  -movflags frag_keyframe+empty_moov \
  -f mp4 pipe:1

# 4K HDR → 1080p SDR (Tone mapping)
ffmpeg -hwaccel videotoolbox -i input.mkv \
  -vf "scale=1920:1080,tonemap=hable" \
  -c:v h264_videotoolbox \
  -b:v 15M \
  -c:a aac -b:a 256k \
  -f mp4 pipe:1

# Audio transcode only (DTS → AAC)
ffmpeg -i input.mkv \
  -c:v copy \
  -c:a aac -b:a 384k -ac 6 \
  -f mp4 pipe:1

# Subtitle burn-in (ASS with styling)
ffmpeg -i input.mkv \
  -vf "ass=subtitle.ass" \
  -c:v h264_videotoolbox \
  -c:a copy \
  -f mp4 pipe:1

# Extract subtitles to WebVTT
ffmpeg -i input.mkv \
  -map 0:s:0 -c:s webvtt \
  output.vtt
```

### Bitrate Guidelines

| Resolution | SDR | HDR10 | Dolby Vision |
|------------|-----|-------|--------------|
| 4K (2160p) | 25-40 Mbps | 40-60 Mbps | 50-80 Mbps |
| 1080p | 8-15 Mbps | 15-20 Mbps | - |
| 720p | 4-8 Mbps | - | - |

## Device Compatibility Matrix

### Your Setup

| Device | HEVC | HDR10 | DV | MKV | Max Bitrate | Best For |
|--------|------|-------|-----|-----|-------------|----------|
| **Samsung 2017 (DLNA)** | ✅ | ✅ | ❌ | ✅ | ~100 Mbps | Remux direct play |
| **Chromecast Ultra** | ✅ | ✅ | ❌ | ❌ | ~80 Mbps | Remux → MP4 |

### Audio Codec Handling

| Source Audio | Samsung DLNA | Chromecast Ultra | Action |
|--------------|--------------|------------------|--------|
| TrueHD/Atmos | ❌ | ❌ | Transcode → AC3 5.1 or AAC |
| DTS-HD MA | Core only | ❌ | Extract core or transcode |
| DTS | ✅ | ❌ | Pass / Transcode AAC |
| AC3/E-AC3 | ✅ | ✅ | Direct |
| AAC | ✅ | ✅ | Direct |

### Subtitle Handling

| Format | DLNA | Chromecast | Recommendation |
|--------|------|------------|----------------|
| SRT (embedded) | ✅ | ❌ | Extract → WebVTT |
| SRT (external) | ⚠️ | ✅ (WebVTT) | Convert + serve |
| ASS/SSA | ⚠️ | ❌ | Burn-in for styling |
| PGS (Blu-ray) | ❌ | ❌ | OCR → SRT → WebVTT or burn-in |

## Implementation Phases

### Phase 1: Foundation (Week 1)
- [ ] Plugin scaffold (Info.json, main.js, global.js)
- [ ] Swift helper with Vapor REST skeleton
- [ ] Health endpoint + helper lifecycle management
- [ ] Basic logging and error handling

### Phase 2: Discovery (Week 1-2)
- [ ] Chromecast discovery via NWBrowser (mDNS)
- [ ] DLNA discovery via SSDP (use CocoaAsyncSocket)
- [ ] Device capability detection
- [ ] Sidebar UI with device list

### Phase 3: Media Server (Week 2)
- [ ] HTTP server with Range request support
- [ ] CORS headers for Chromecast
- [ ] DLNA headers for Samsung
- [ ] Stream proxy for remote URLs
- [ ] Media file probing (FFprobe)

### Phase 4: Chromecast Protocol (Week 2-3)
- [ ] TLS connection to Chromecast
- [ ] CASTV2 message framing (Protobuf)
- [ ] Connection/Heartbeat channels
- [ ] Media channel (LOAD, PLAY, PAUSE, SEEK)
- [ ] Subtitle track support (WebVTT)

### Phase 5: DLNA Protocol (Week 3)
- [ ] SOAP client for AVTransport
- [ ] SetAVTransportURI + DIDL-Lite metadata
- [ ] Play/Pause/Stop/Seek actions
- [ ] GetPositionInfo polling
- [ ] RenderingControl for volume

### Phase 6: Transcoding (Week 3-4)
- [ ] FFmpeg integration (bundled or system)
- [ ] VideoToolbox hardware acceleration
- [ ] Profile-based transcoding
- [ ] Live transcode streaming (fragmented MP4)
- [ ] Subtitle extraction → WebVTT
- [ ] Subtitle burn-in for ASS

### Phase 7: UI & Polish (Week 4)
- [ ] Overlay cast indicator
- [ ] Mini controls in overlay
- [ ] Preferences panel (quality, buffer, etc.)
- [ ] OSD notifications
- [ ] Position sync (IINA ↔ Cast device)
- [ ] Error handling and recovery
- [ ] Reconnection logic

### Phase 8: Advanced (Future)
- [ ] Adaptive bitrate based on buffer status
- [ ] Queue/playlist support
- [ ] Multiple device casting
- [ ] Cast from URL (paste HTTP link)
- [ ] Integration with Stremio streams

## Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture | Hybrid (JS + Swift helper) | JavaScriptCore lacks network sockets |
| HTTP Framework | Vapor 4 | Modern async Swift, excellent perf |
| SSDP | CocoaAsyncSocket | Network.framework has multicast bugs |
| Chromecast | Custom CASTV2 impl | OpenCastSwift is outdated |
| Transcoding | FFmpeg + VideoToolbox | Best macOS HW acceleration |
| IPC | REST over localhost | Simple, debuggable, language-agnostic |
| Default mode | Direct Play | Preserve quality, no latency |
| Buffer strategy | 60s prebuffer | Smooth playback for high-bitrate |

## References

- `references/iina-architecture.md` — IINA internals, plugin APIs, hooks
- `references/protocols.md` — CASTV2 and DLNA/SOAP protocol details
- `references/transcoding.md` — FFmpeg profiles, VideoToolbox, codec handling
- `references/stremio-patterns.md` — Patterns learned from Stremio V4

## Critical Implementation Notes

1. **SSDP on macOS**: Network.framework has bugs with multicast UDP responses. Use CocoaAsyncSocket (GCDAsyncUdpSocket) instead.

2. **Chromecast TLS**: Self-signed certificate — disable validation for the 8009 connection.

3. **Helper distribution**: Don't bundle binary in plugin (Gatekeeper issues). Download to `@data/bin/` at first run.

4. **MKV on Chromecast**: Always remux to MP4, even if codecs match. Chromecast rejects MKV container.

5. **HDR tone mapping**: If transcoding HDR → SDR, use FFmpeg `tonemap` filter to avoid washed-out colors.

6. **Subtitle styling**: ASS effects (karaoke, positioning) are lost in WebVTT. Burn-in is the only way to preserve them.

7. **High-bitrate streams**: For 80+ Mbps remux, ensure Ethernet connection and increase buffer to 60-120s.

8. **Position sync**: Poll every 1-2s max. More frequent = unnecessary traffic and potential rate limiting.

9. **Audio passthrough**: TrueHD/DTS-HD cannot be transcoded in real-time for 50GB files. Extract lossy core or pre-process.

10. **Stremio pattern**: Follow their "server serves media, client controls" pattern. Never stream through the plugin JS directly.
