# IINA Cast Plugin

Cast videos from [IINA](https://iina.io) to Chromecast, DLNA/UPnP, and AirPlay 2 devices with full quality control.

![macOS](https://img.shields.io/badge/macOS-12.0+-blue)
![IINA](https://img.shields.io/badge/IINA-1.4.0+-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

## Features

- 🎬 **Direct Play** — Stream original quality without transcoding
- 📺 **Chromecast** — Full CASTV2 protocol support for all Chromecast devices including Ultra (4K HDR)
- 📡 **DLNA/UPnP** — Cast to Samsung, LG, Sony TVs with SOAP/AVTransport
- 🍎 **AirPlay 2** — Stream to Apple TV and AirPlay 2-compatible devices
- 🔄 **Smart Transcoding** — Automatic format conversion when needed (VideoToolbox HW acceleration)
- 🎚️ **Quality Control** — Choose resolution, bitrate, audio track
- 💬 **Subtitles** — External WebVTT or burn-in for styled ASS
- ⏱️ **Buffer Control** — Pre-buffer for smooth high-bitrate playback
- 🔗 **Position Sync** — Seamless playback control across all device types

## Screenshots

*Coming soon*

## Requirements

- macOS 12.0 (Monterey) or later
- IINA 1.4.0 or later
- Swift 5.9+ (for building from source)
- FFmpeg (optional, for transcoding)

### Tested Devices

- ✅ Chromecast (2nd gen, 3rd gen, Ultra)
- ✅ Google TV / Nest Hub
- ✅ Samsung Smart TVs (DLNA)
- ✅ LG webOS TVs (DLNA)
- ✅ Apple TV 4K (AirPlay 2)
- ✅ AirPlay 2-compatible speakers

## Installation

### From Release

1. Download `iina-cast.iinaplugin` from [Releases](../../releases)
2. Double-click to install in IINA
3. Enable in IINA → Preferences → Plugins

### From Source

```bash
git clone https://github.com/paulthery/IINA-Cast-Plugin.git
cd IINA-Cast-Plugin

# Build helper binary
cd helper
swift build -c release
cd ..

# Copy helper binary into plugin
mkdir -p iina-cast.iinaplugin/helper
cp helper/.build/arm64-apple-macosx/release/IINACastHelper iina-cast.iinaplugin/helper/

# Remove quarantine attribute (required for unsigned binaries)
xattr -cr iina-cast.iinaplugin/helper/IINACastHelper

# Install plugin
mkdir -p ~/Library/Application\ Support/IINA/plugins
cp -r iina-cast.iinaplugin ~/Library/Application\ Support/IINA/plugins/

# Restart IINA to load the plugin
```

**Note**: The correct IINA plugins path is `~/Library/Application Support/IINA/plugins/`, not `com.colliderli.iina`.

## Usage

1. Open a video in IINA
2. Click the **Cast** tab in the sidebar (or press `⌘⇧C`)
3. Select your device
4. Choose quality settings
5. Click **Cast**

### Supported Formats

| Format | Chromecast | DLNA/UPnP | AirPlay 2 | Transcode |
|--------|------------|-----------|-----------|-----------|
| MP4 (H.264/AAC) | ✅ | ✅ | ✅ | - |
| MKV (H.264/AAC) | ⚠️ Remux | ✅ | ✅ | Optional |
| HEVC/HDR10 | ✅ Ultra only | ✅ | ✅ Apple TV 4K | 3rd gen |
| Dolby Vision | ⚠️ HDR10 fallback | ⚠️ HDR10 fallback | ✅ Apple TV 4K | - |
| DTS/TrueHD | - | - | - | ✅ AAC/AC3 |
| AV1 | ❌ | ❌ | ❌ | ✅ H.264/HEVC |

## Development

This project uses a **hybrid architecture**:

- `iina-cast.iinaplugin/` — IINA JavaScript plugin (UI, controls)
- `helper/` — Swift binary (device discovery, protocols, media server)

### Swift Dependencies

- **Vapor** — HTTP server for REST API and media serving
- **SwiftNIO/NIOSSL** — Non-blocking networking for Chromecast CASTV2
- **SwiftProtobuf** — Protobuf serialization (Chromecast messages)
- **ArgumentParser** — CLI argument parsing

All protocols are **implemented from scratch** without external casting libraries.

### Documentation

- [SKILL.md](SKILL.md) — Complete development guide and protocol specifications
- `references/protocols.md` — CASTV2 and DLNA protocol details
- `references/transcoding.md` — FFmpeg profiles and commands
- `references/iina-architecture.md` — IINA plugin API reference
- `references/stremio-patterns.md` — Patterns from Stremio V4

### Building

```bash
# Build helper
cd helper
swift build -c release

# Run helper (for testing)
.build/release/IINACastHelper --port 9876

# Test API
curl http://localhost:9876/devices
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│  IINA                                           │
│  ┌───────────────────────────────────────────┐  │
│  │  Plugin (JavaScript)                      │  │
│  │  - Sidebar UI (device picker)             │  │
│  │  - Overlay (cast indicator)               │  │
│  │  - Position sync                          │  │
│  └───────────────────────────────────────────┘  │
│                      │ HTTP REST                │
└──────────────────────┼──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│  Helper (Swift)                                  │
│  - Device discovery (mDNS, SSDP)                │
│  - ChromecastClient (CASTV2 over TLS)           │
│  - DLNAClient (SOAP/AVTransport)                │
│  - AirPlayClient (HTTP + Binary Plist)          │
│  - Media server (Range requests, DLNA headers)  │
│  - Transcoding (FFmpeg + VideoToolbox)          │
└──────────────────────┬──────────────────────────┘
                       │
         ┌─────────────┼─────────────┐
         ▼             ▼             ▼
┌──────────────┐ ┌──────────┐ ┌─────────────┐
│ Chromecast   │ │ DLNA TV  │ │  Apple TV   │
│ (TLS:8009)   │ │ (HTTP)   │ │ (HTTP:7000) │
└──────────────┘ └──────────┘ └─────────────┘
```

### Protocol Implementation

- **Chromecast (CASTV2)**: Custom Protobuf over TLS with NIO/NIOSSL
- **DLNA/UPnP**: SSDP discovery + SOAP AVTransport control
- **AirPlay 2**: HTTP endpoints with binary plist payloads

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with real devices
5. Submit a pull request

## Known Issues

- **DLNA**: Subtitle support varies by TV manufacturer
- **Chromecast**: Dolby Vision falls back to HDR10 on non-Ultra devices
- **AirPlay 2**: Volume control requires system-level API (not yet implemented)
- **All protocols**: Very high bitrate (100+ Mbps) may require Ethernet connection
- **Transcoding**: Requires FFmpeg installation for format conversion

## Author

**Paul Thery** — [GitHub](https://github.com/paulthery)

## Acknowledgments

- Inspired by [Stremio](https://stremio.com) V4 casting implementation
- [IINA](https://iina.io) for the excellent plugin system

## License

MIT License - see [LICENSE](LICENSE) for details
