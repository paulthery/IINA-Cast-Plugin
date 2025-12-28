# IINA Architecture Reference

Technical reference for IINA internals, plugin system, and integration points for the casting plugin.

---

## Core Architecture

IINA is a **pure Swift** application (95.9%) using AppKit for native macOS UI. It wraps **libmpv** for media playback.

### Class Hierarchy

```
AppDelegate
└── PlayerCore[] (Multi-instance coordinator)
        ├── MPVController        → libmpv C API wrapper
        ├── MainWindowController → Main video window
        ├── MiniPlayerWindowController → Mini mode
        ├── PlaybackInfo         → Thread-safe state container
        └── JavascriptPluginInstance[] → Plugin instances
```

Each player window is independent with its own PlayerCore, MPVController, and plugin instances.

---

## PlayerCore

Central coordinator for one player instance. Manages mpv lifecycle, UI synchronization, and plugin communication.

### Key Properties

```swift
class PlayerCore {
    let mpv: MPVController
    let info: PlaybackInfo
    var mainWindow: MainWindowController?
    var plugins: [JavascriptPluginInstance] = []
    
    // State
    var isPlaying: Bool
    var currentURL: URL?
    var duration: Double
    var position: Double
}
```

### Key Methods

```swift
// Playback control
func openURL(_ url: URL, options: [String: Any]?)
func pause()
func resume()
func seek(to: Double, exact: Bool)
func stop()

// Track selection
func setAudioTrack(_ index: Int)
func setSubtitle(_ index: Int)
func loadExternalSubtitle(_ url: URL)

// UI sync
func syncUI()  // Called on main thread after mpv events
```

---

## MPVController

Wraps the libmpv C API via Swift bridging header.

### Initialization Sequence

```swift
// 1. Create mpv context
mpv = mpv_create()

// 2. Configure options
mpv_set_option_string(mpv, "vo", "libmpv")
mpv_set_option_string(mpv, "input-default-bindings", "yes")

// 3. Initialize
mpv_initialize(mpv)

// 4. Register property observers
mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
// ... etc

// 5. Start event loop
startEventLoop()
```

### Command Execution

```swift
// Synchronous commands
func command(_ cmd: MPVCommand, args: [String]? = nil) {
    var cargs = [cmd.rawValue] + (args ?? [])
    mpv_command(mpv, &cargs)
}

// Common commands
mpv.command(.loadfile, args: ["/path/to/video.mp4"])
mpv.command(.seek, args: ["10", "relative"])
mpv.command(.seek, args: ["120", "absolute"])
mpv.command(.stop)
```

### Property Access

```swift
// Getters by type
func getString(_ name: String) -> String?
func getInt(_ name: String) -> Int
func getDouble(_ name: String) -> Double
func getFlag(_ name: String) -> Bool
func getNode(_ name: String) -> Any?  // Complex structures

// Setters
func setString(_ name: String, _ value: String)
func setInt(_ name: String, _ value: Int)
func setDouble(_ name: String, _ value: Double)
func setFlag(_ name: String, _ value: Bool)
```

### Properties Useful for Casting

| Property | Type | Description |
|----------|------|-------------|
| `path` | String | Current file path or URL |
| `stream-open-filename` | String | Original URL before redirects |
| `time-pos` | Double | Current position (seconds) |
| `duration` | Double | Total duration (seconds) |
| `pause` | Bool | Paused state |
| `volume` | Double | Volume (0-100) |
| `mute` | Bool | Muted state |
| `video-params/w` | Int | Video width |
| `video-params/h` | Int | Video height |
| `video-codec` | String | Video codec name |
| `audio-codec` | String | Audio codec name |
| `track-list` | Node | All tracks (video, audio, sub) |
| `metadata` | Node | Media metadata |

### Event System

Events are processed in a dedicated DispatchQueue:

```swift
func handleEvent(_ event: mpv_event) {
    switch event.event_id {
    case MPV_EVENT_FILE_LOADED:
        // New file loaded, metadata available
        onFileLoaded()
        
    case MPV_EVENT_END_FILE:
        // Playback ended
        onEndFile(event.data)
        
    case MPV_EVENT_PROPERTY_CHANGE:
        // Observed property changed
        let prop = event.data.assumingMemoryBound(to: mpv_event_property.self)
        onPropertyChange(prop.pointee)
        
    case MPV_EVENT_SEEK:
        // Seek completed
        onSeekDone()
        
    default:
        break
    }
}
```

### Hook System

Hooks allow intercepting operations before they complete:

```swift
// Available hooks
enum MPVHook: String {
    case onLoad = "on_load"           // Before file loads
    case onLoadFail = "on_load_fail"  // After load failure
    case onPreloaded = "on_preloaded" // After metadata parsed
    case onUnload = "on_unload"       // Before file closes
}

// Registering a hook (done via plugin JS API)
mpv.addHook("on_load", priority: 50) { next in
    // Do something before load
    // ...
    next()  // Continue loading
}
```

---

## PlaybackInfo

Thread-safe state container with NSLock protection.

```swift
class PlaybackInfo {
    // Playback state
    var state: PlayerState  // .idle, .playing, .paused, .seeking
    var currentURL: URL?
    var duration: Double
    var position: Double
    
    // Media info
    var videoWidth: Int
    var videoHeight: Int
    var videoBitrate: Int
    var audioBitrate: Int
    
    // Tracks (NSLock protected)
    var audioTracks: [MPVTrack]
    var videoTracks: [MPVTrack]
    var subTracks: [MPVTrack]
    
    // Playlist
    var playlist: [MPVPlaylistItem]
}

struct MPVTrack {
    let id: Int
    let type: TrackType  // .video, .audio, .sub
    let title: String?
    let lang: String?
    let codec: String?
    let isDefault: Bool
    let isForced: Bool
    let isExternal: Bool
}
```

---

## Plugin System

IINA uses **JavaScriptCore** (Safari's engine) for plugins.

### Plugin Lifecycle

1. **IINA starts** → Load `global.js` for each enabled plugin
2. **Player window opens** → Create `JavascriptPluginInstance`
3. **Load `main.js`** in isolated JSContext
4. **Plugin registers** hooks, events, UI
5. **Window closes** → Cleanup instance

### JSContext Setup

```swift
class JavascriptPluginInstance {
    let context: JSContext
    let player: PlayerCore
    
    func setup() {
        // Expose iina global object
        context.setObject(makeIINAObject(), forKeyedSubscript: "iina" as NSString)
        
        // Load entry script
        let script = loadScript("main.js")
        context.evaluateScript(script)
    }
    
    func makeIINAObject() -> [String: Any] {
        return [
            "core": JavascriptAPICore(self),
            "mpv": JavascriptAPIMpv(self),
            "event": JavascriptAPIEvent(self),
            "http": JavascriptAPIHttp(self),
            "overlay": JavascriptAPIOverlay(self),
            "sidebar": JavascriptAPISidebar(self),
            "menu": JavascriptAPIMenu(self),
            "utils": JavascriptAPIUtils(self),
            "file": JavascriptAPIFile(self),
            "preferences": JavascriptAPIPreferences(self),
            "console": JavascriptAPIConsole(self)
        ]
    }
}
```

---

## Plugin APIs

### iina.core

```javascript
// Playback control
core.open(url)
core.pause()
core.resume()
core.stop()
core.seek(seconds)
core.seekTo(position)

// OSD
core.osd(message)
core.osd(message, duration)

// Status
core.status
// → { url, title, duration, position, paused, volume, ... }

// Window
core.window.toggleFullScreen()
core.window.togglePIP()
```

### iina.mpv

```javascript
// Properties
mpv.getString("path")
mpv.getNumber("time-pos")
mpv.getFlag("pause")
mpv.getNode("track-list")

mpv.setString("sub-file-paths", "/path")
mpv.setNumber("volume", 80)
mpv.setFlag("pause", true)

// Commands
mpv.command("loadfile", ["/path/to/file.mp4"])
mpv.command("seek", ["10", "relative"])

// Hooks (critical for casting!)
mpv.addHook("on_load", 50, async (next) => {
    const url = mpv.getString("stream-open-filename");
    // Intercept and potentially redirect
    next();
});
```

### iina.event

```javascript
// Subscribe to events
event.on("iina.file-loaded", () => { ... });
event.on("iina.window-will-close", () => { ... });

// mpv property changes
event.on("mpv.time-pos.changed", () => { ... });
event.on("mpv.pause.changed", () => { ... });
event.on("mpv.volume.changed", () => { ... });

// Unsubscribe
const handler = event.on("iina.file-loaded", fn);
event.off(handler);
```

### iina.http

```javascript
// GET request
const response = await http.get(url);
// → { status, headers, text, data }

// POST request
const response = await http.post(url, {
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(data)
});

// Download file
await http.download(url, "@data/bin/helper");
```

### iina.overlay

```javascript
// Simple mode (quick HTML)
overlay.simpleMode();
overlay.setContent("<div>Cast active</div>");
overlay.setStyle("div { color: white; }");
overlay.show();
overlay.hide();

// Full mode (load HTML file)
overlay.loadFile("ui/overlay.html");
overlay.setClickable(true);

// Communication
overlay.postMessage("eventName", data);
overlay.onMessage("action", (data) => { ... });
```

### iina.sidebar

```javascript
// Load sidebar content
sidebar.loadFile("ui/sidebar.html");
sidebar.show();
sidebar.hide();

// Communication
sidebar.postMessage("devices", deviceList);
sidebar.onMessage("select", (data) => { ... });
```

### iina.utils

```javascript
// Execute binary
const result = await utils.exec("/path/to/binary", ["arg1", "arg2"]);
// → { stdout, stderr, exitCode }

// Dialogs
utils.showAlert("Title", "Message");
const choice = await utils.showConfirm("Title", "Question?");
const path = await utils.chooseFile({ types: ["mp4", "mkv"] });
```

### iina.file

```javascript
// File operations (sandboxed)
file.exists("@data/config.json")
file.read("@data/config.json")
file.write("@data/config.json", content)
file.delete("@tmp/tempfile")

// Path resolution
file.resolvePath("@data/bin/helper")
// → /Users/.../Library/Application Support/com.collider.iina/plugins/io.github.iina-cast/data/bin/helper

// Special paths
// @data/   → Plugin persistent storage
// @tmp/    → Plugin temporary files
// @plugins/ → Plugin bundle (read-only)
```

### iina.preferences

```javascript
// Get/set plugin preferences
const value = preferences.get("transcodeBitrate");
preferences.set("transcodeBitrate", 20000);

// Defaults from Info.json preferenceDefaults
```

---

## UI Integration Points

### OSD (On-Screen Display)

Quick message overlay:
```javascript
core.osd("Casting to Samsung TV");
core.osd("Buffering...", 5);  // 5 second duration
```

### Video Overlay

HTML layer over video — ideal for cast indicator:

```javascript
// In main.js
overlay.simpleMode();
overlay.setStyle(`
    .cast-badge {
        position: fixed;
        top: 20px;
        right: 20px;
        background: rgba(0,0,0,0.8);
        padding: 8px 16px;
        border-radius: 8px;
        color: white;
        font-family: -apple-system, sans-serif;
    }
`);
overlay.setContent('<div class="cast-badge">📺 Casting</div>');
overlay.show();
```

### Sidebar Tab

Device picker interface:

```json
// Info.json
{
    "sidebarTab": { "name": "Cast" }
}
```

```javascript
// main.js
sidebar.loadFile("ui/sidebar.html");

// Send data to sidebar
sidebar.postMessage("devices", [
    { id: "cc-1", name: "Living Room", type: "chromecast" },
    { id: "dlna-1", name: "Samsung TV", type: "dlna" }
]);

// Receive actions
sidebar.onMessage("cast", (data) => {
    startCasting(data.deviceId);
});
```

### Menu Items

```javascript
const castMenu = menu.item("Casting");
castMenu.addSubmenuItem(menu.item("Living Room TV", () => castTo("cc-1")));
castMenu.addSubmenuItem(menu.item("Samsung TV", () => castTo("dlna-1")));
castMenu.addSubmenuItem(menu.separator());
castMenu.addSubmenuItem(menu.item("Stop Casting", stopCasting));
menu.addItem(castMenu);
```

---

## Sandboxing & Permissions

Plugins declare permissions in Info.json:

```json
{
    "permissions": [
        "show-osd",         // core.osd()
        "video-overlay",    // overlay API
        "network-request",  // http API
        "file-system"       // file API, utils.exec()
    ]
}
```

### File System Sandbox

| Path | Permission | Description |
|------|------------|-------------|
| `@data/` | Read/Write | Plugin persistent storage |
| `@tmp/` | Read/Write | Temporary files |
| `@plugins/` | Read-only | Plugin bundle |
| System paths | Denied | No access outside sandbox |

### Network

- `http.get/post` — Full HTTP client
- No raw socket access (JavaScriptCore limitation)
- Helper binary needed for UDP (SSDP) and TLS (CASTV2)

---

## Hook Usage for Casting

The `on_load` hook is critical for intercepting playback:

```javascript
mpv.addHook("on_load", 50, async (next) => {
    const url = mpv.getString("stream-open-filename");
    
    if (castingEnabled && currentDevice) {
        // Redirect to cast device instead of local playback
        const castUrl = await prepareCastUrl(url);
        await startCasting(castUrl, currentDevice);
        
        // Option 1: Continue local playback (mirroring)
        next();
        
        // Option 2: Stop local playback (cast only)
        // Don't call next(), or call core.stop() after
    } else {
        next();
    }
});
```

Priority values: Lower = earlier execution. Use 50 for normal hooks.

---

## Helper Binary Integration

Pattern for launching and managing a helper process:

```javascript
// global.js
const HELPER_PATH = "@data/bin/iina-cast-helper";
const HELPER_PORT = 9876;

async function ensureHelper() {
    // Download if missing
    if (!file.exists(HELPER_PATH)) {
        await http.download(DOWNLOAD_URL, HELPER_PATH);
        await utils.exec("chmod", ["+x", file.resolvePath(HELPER_PATH)]);
    }
    
    // Check if running
    try {
        await http.get(`http://localhost:${HELPER_PORT}/health`);
        return true;
    } catch {
        // Start it
        await utils.exec(file.resolvePath(HELPER_PATH), [
            "--port", String(HELPER_PORT),
            "--daemon"
        ]);
        
        // Wait for startup
        for (let i = 0; i < 10; i++) {
            await sleep(500);
            try {
                await http.get(`http://localhost:${HELPER_PORT}/health`);
                return true;
            } catch {}
        }
        return false;
    }
}
```

---

## Build & Dependencies

IINA uses a pure Xcode project (no package managers for main app).

### Plugin Distribution

Plugins are distributed as `.iinaplugin` bundles:

```
iina-cast.iinaplugin/
├── Info.json
├── main.js
├── global.js
├── ui/
│   ├── sidebar.html
│   └── overlay.html
├── preferences.html
└── (no binary — downloaded at runtime)
```

### Installation Location

```
~/Library/Application Support/com.colliderli.iina/plugins/
└── io.github.iina-cast.iinaplugin/
    ├── (plugin files)
    └── data/
        └── bin/
            └── iina-cast-helper  (downloaded)
```
