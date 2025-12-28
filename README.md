# IINA Cast Plugin

Cast videos from [IINA](https://iina.io) to Chromecast and DLNA/UPNP devices with full quality control.

![macOS](https://img.shields.io/badge/macOS-12.0+-blue)
![IINA](https://img.shields.io/badge/IINA-1.4.0+-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

## Features

- 🎬 **Direct Play** — Stream original quality without transcoding
- 📺 **Chromecast** — Support for all Chromecast devices including Ultra (4K HDR)
- 📡 **DLNA/UPNP** — Cast to Samsung, LG, Sony TVs and more
- 🔄 **Smart Transcoding** — Automatic format conversion when needed (VideoToolbox HW acceleration)
- 🎚️ **Quality Control** — Choose resolution, bitrate, audio track
- 💬 **Subtitles** — External WebVTT or burn-in for styled ASS
- ⏱️ **Buffer Control** — Pre-buffer for smooth high-bitrate playback
- 🔗 **Position Sync** — Seamless control between IINA and cast device

## Screenshots

*Coming soon*

## Requirements

- macOS 12.0 (Monterey) or later
- IINA 1.4.0 or later
- FFmpeg (optional, for transcoding)

## Installation

### From Release

1. Download `iina-cast.iinaplugin` from [Releases](../../releases)
2. Double-click to install in IINA
3. Enable in IINA → Preferences → Plugins

### From Source

```bash
git clone https://github.com/yourusername/IINA-Cast-Plugin.git
cd IINA-Cast-Plugin

# Build helper binary
cd helper
swift build -c release
cd ..

# Install plugin
cp -r iina-cast.iinaplugin ~/Library/Application\ Support/com.colliderli.iina/plugins/
```

## Usage

1. Open a video in IINA
2. Click the **Cast** tab in the sidebar (or press `⌘⇧C`)
3. Select your device
4. Choose quality settings
5. Click **Cast**

### Supported Formats

| Format | Direct Play | Needs Transcode |
|--------|-------------|-----------------|
| MP4 (H.264/AAC) | ✅ All devices | - |
| MKV (H.264/AAC) | ✅ DLNA only | Chromecast (remux) |
| HEVC/HDR10 | ✅ Ultra/DLNA | Chromecast 3rd gen |
| Dolby Vision | ⚠️ HDR10 fallback | - |
| DTS/TrueHD | - | ✅ Transcode to AAC/AC3 |

## Development

This project uses a **hybrid architecture**:

- `iina-cast.iinaplugin/` — IINA JavaScript plugin (UI, controls)
- `helper/` — Swift binary (device discovery, protocols, transcoding)

### Documentation

- `SKILL.md` — Complete development guide
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
│  - Protocol handling (CASTV2, SOAP)             │
│  - Media server (Range requests)                │
│  - Transcoding (FFmpeg + VideoToolbox)          │
└──────────────────────┬──────────────────────────┘
                       │
         ┌─────────────┴─────────────┐
         ▼                           ▼
┌─────────────────┐         ┌─────────────────┐
│  Chromecast     │         │  DLNA TV        │
└─────────────────┘         └─────────────────┘
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with real devices
5. Submit a pull request

## Known Issues

- DLNA subtitle support varies by TV manufacturer
- Dolby Vision falls back to HDR10 (no consumer device supports DV via cast)
- Very high bitrate (100+ Mbps) may require Ethernet

## Acknowledgments

- Inspired by [Stremio](https://stremio.com) V4 casting implementation
- [IINA](https://iina.io) for the excellent plugin system
- [OpenCastSwift](https://github.com/mhmiles/OpenCastSwift) for Chromecast reference

## License

MIT License - see [LICENSE](LICENSE) for details
