# Stremio V4 Casting Patterns

Lessons learned from Stremio's proven casting implementation. These patterns have been battle-tested with thousands of users streaming torrent and debrid content.

---

## Architecture Pattern: Separation of Concerns

Stremio V4's casting worked because of clear separation:

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  UI Layer        │     │  Server Layer    │     │  Protocol Layer  │
│  (Web App)       │────▶│  (server.js)     │────▶│  (Device)        │
│                  │     │                  │     │                  │
│  - Device picker │     │  - Discovery     │     │  - Chromecast    │
│  - Controls      │     │  - Media server  │     │  - DLNA          │
│  - Status        │     │  - Transcoding   │     │                  │
└──────────────────┘     └──────────────────┘     └──────────────────┘
         │                        │                        │
         │   HTTP REST API        │   Protocol-specific    │
         │◀──────────────────────▶│◀──────────────────────▶│
```

**Key insight**: The UI never talks directly to cast devices. All communication goes through the server layer.

**Apply to IINA Cast**: Plugin JS ↔ Swift Helper ↔ Cast Devices

---

## The stremio-cast Protocol

Stremio created a dead-simple HTTP abstraction over casting protocols. Instead of dealing with CASTV2 or SOAP, clients use a unified REST interface:

### State Model

Single endpoint with GET/POST:

```
GET  /player → Current state
POST /player → Modify state
```

State properties:

| Property | Type | R/W | Description |
|----------|------|-----|-------------|
| `source` | URL | R/W | Media URL (set to start playback) |
| `paused` | Boolean | R/W | Pause state |
| `time` | Number | R/W | Current position (R) / Seek target (W) |
| `volume` | 0-1 | R/W | Volume level |
| `state` | 0-7 | R | Player state enum |
| `length` | Number | R | Duration |

State values:
```
0 = IDLE
1 = OPENING
2 = BUFFERING
3 = PLAYING
4 = PAUSED
5 = STOPPED
6 = ENDED
7 = ERROR
```

### Usage Examples

```javascript
// Start playback
POST /player
{ "source": "http://192.168.1.100:8080/video.mp4" }

// Get status
GET /player
→ { "state": 3, "time": 42.5, "length": 7200, "paused": false, "volume": 1 }

// Seek
POST /player
{ "time": 120 }

// Pause
POST /player
{ "paused": true }

// Volume
POST /player
{ "volume": 0.5 }

// Stop
POST /player
{ "source": null }
```

**Apply to IINA Cast**: Adopt this simple state model for the REST API. It's intuitive and debuggable with curl.

---

## Video Abstraction Layer (@stremio/stremio-video)

Stremio's video module provides a unified interface across different player backends:

```javascript
// Unified interface
player.dispatch({ type: 'load', stream: {...}, subtitles: [...] })
player.dispatch({ type: 'play' })
player.dispatch({ type: 'pause' })
player.dispatch({ type: 'seek', time: 120 })
player.dispatch({ type: 'setVolume', volume: 0.5 })

// Observe properties
player.on('propChanged', (prop, value) => {
    switch(prop) {
        case 'time': updateTimeDisplay(value); break;
        case 'state': handleStateChange(value); break;
        case 'buffering': showBuffering(value); break;
    }
});
```

Supported backends:
- `HTMLVideo` — Web `<video>` element
- `ShellVideo` — MPV via shell (desktop)
- `ChromecastVideo` — Chromecast devices
- `TizenVideo` — Samsung Tizen TVs
- `WebOSVideo` — LG WebOS TVs

**Apply to IINA Cast**: Create a Swift `CastPlayer` protocol with implementations for Chromecast and DLNA. The plugin JS only talks to this abstraction.

---

## Server as Media Proxy

Stremio's server.js acts as a **media proxy** between content sources and cast devices:

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│  Content Source │         │  server.js      │         │  Cast Device    │
│                 │         │                 │         │                 │
│  - Local file   │────────▶│  HTTP Server    │◀────────│  Pulls via HTTP │
│  - Torrent      │  Stream │  (port 11470)   │  Request│                 │
│  - Debrid URL   │         │                 │         │                 │
│  - Remote URL   │         │  - Range support│         │                 │
│                 │         │  - Transcoding  │         │                 │
│                 │         │  - Subtitles    │         │                 │
└─────────────────┘         └─────────────────┘         └─────────────────┘
```

Why proxy instead of direct URL?
1. **Torrent streams** — Cast devices can't speak BitTorrent
2. **Transcoding** — Server can transcode incompatible formats
3. **Range requests** — Server can handle seeking uniformly
4. **Subtitles** — Server can serve converted WebVTT
5. **Network isolation** — Cast device may not reach source directly

**Apply to IINA Cast**: The Swift helper must proxy all media, even local files. This ensures consistent behavior and enables transcoding.

---

## Buffering Strategy

Stremio's torrent-based playback requires aggressive buffering:

### Server Settings (server-settings.json)

```json
{
    "btDownloadSpeedSoftLimit": 2621440,
    "btDownloadSpeedHardLimit": 5242880,
    "btMinPeersForStable": 5
}
```

### Buffer Status Communication

The server exposes buffer status that the UI polls:

```javascript
GET /stream/status
→ {
    "buffered": 0.45,        // 45% of buffer filled
    "downloadSpeed": 2500000, // bytes/sec
    "peers": 12
}
```

UI adapts quality based on buffer:
- Buffer < 20% → Show spinner, reduce quality
- Buffer 20-40% → Warning state
- Buffer > 60% → Stable, can increase quality

**Apply to IINA Cast**: 
- For local files: Minimal buffering needed
- For remote URLs: Pre-buffer 30-60s before starting cast
- Monitor device buffer via GetPositionInfo (DLNA) or MEDIA_STATUS (Chromecast)

---

## Error Recovery

Stremio implements resilient error handling:

### Connection Loss

```javascript
// Chromecast heartbeat failure
onHeartbeatTimeout: () => {
    // Try reconnect 3 times
    for (let i = 0; i < 3; i++) {
        if (await reconnect()) return;
        await sleep(1000 * (i + 1));  // Exponential backoff
    }
    // Give up, notify user
    emit('disconnected');
}
```

### Playback Error

```javascript
onPlaybackError: (error) => {
    if (error.code === 'MEDIA_NOT_SUPPORTED') {
        // Try with transcoding
        const transcodedUrl = await transcode(mediaUrl);
        await load(transcodedUrl);
    } else if (error.code === 'NETWORK_ERROR') {
        // Retry with backoff
        await retry(load, mediaUrl);
    }
}
```

### DLNA Device Quirks

Stremio documented common DLNA issues:

| TV Brand | Quirk | Workaround |
|----------|-------|------------|
| Samsung | Ignores DIDL-Lite duration | Send duration in filename |
| LG | Requires specific DLNA flags | Use full protocol info |
| Sony | Strict content-type checking | Probe and set exact MIME |
| Generic | No MKV support | Always remux to MP4 |

**Apply to IINA Cast**: Build a device quirks database. Start with common issues and let users report new ones.

---

## Why Stremio Dropped DLNA

Stremio officially dropped DLNA in v4.5 (July 2019). From their blog:

> "DLNA/UPnP is a legacy protocol with insufficient documentation... Each TV manufacturer has their own interpretation. Testing all combinations is impossible."

Key problems:
1. **Inconsistent implementations** — Every TV brand is different
2. **No error feedback** — DLNA devices often fail silently
3. **Limited codec support** — Many TVs reject modern formats
4. **Subtitle hell** — No standard subtitle delivery method
5. **Maintenance burden** — Huge support volume for little benefit

**Lesson for IINA Cast**: 
- Prioritize Chromecast (consistent implementation)
- Support DLNA but with clear "best effort" messaging
- Document known-working TV models
- Provide escape hatch: "Doesn't work? Try Chromecast"

---

## Why Chromecast Broke in V5

Stremio V5 moved from QtWebEngine to native system WebView. The problem:

- QtWebEngine (V4) = Full Chromium = Google Cast APIs available
- System WebView (V5) = Safari/Edge = No Cast APIs

The **stremio-community-v5** fork solved this by using **WebView2** (Microsoft Edge) on Windows, which is Chromium-based and supports Cast.

**Lesson for IINA Cast**: 
- Don't rely on WebView cast APIs
- Implement protocols directly in the helper binary
- This gives us full control and cross-platform consistency

---

## HLS Transcoding (Future Feature)

Stremio's HLS transcoder enables adaptive streaming:

```
/hlsv2/{session-id}/video0.m3u8
```

Playlist example:
```
#EXTM3U
#EXT-X-VERSION:4
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:6.0,
/hlsv2/abc123/segment-0.ts
#EXTINF:6.0,
/hlsv2/abc123/segment-1.ts
...
```

Benefits:
- Adaptive bitrate based on network
- Native support in many players
- Good for unstable connections

**Apply to IINA Cast** (future): HLS could be useful for:
- Chromecast via HLS.js
- Very unstable networks
- Multi-device casting (same HLS stream)

---

## Key Takeaways for IINA Cast

1. **Server-centric architecture** — All media goes through the helper binary

2. **Simple REST API** — Unified state model across protocols

3. **Protocol abstraction** — UI doesn't know Chromecast vs DLNA

4. **Proxy everything** — Even local files go through HTTP server

5. **Buffer before cast** — Pre-buffer for smooth start

6. **Graceful degradation** — Try direct play → remux → transcode

7. **Device quirks database** — Document what works where

8. **Chromecast first** — More consistent, better documented

9. **Clear error messages** — Tell users what went wrong and how to fix

10. **Don't fight DLNA** — It's fragile; set expectations appropriately
