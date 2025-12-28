/**
 * IINA Cast Plugin - Per-Player Entry
 * This runs for each player window instance
 */

const { core, mpv, event, http, overlay, sidebar, preferences, console } = iina;

// Configuration
const HELPER_URL = `http://localhost:${preferences.get("helperPort") || 9876}`;

// State
let castingActive = false;
let currentDevice = null;
let deviceList = [];

// ============================================================================
// Device Discovery & Management
// ============================================================================

async function refreshDevices() {
    try {
        const response = await http.get(`${HELPER_URL}/devices`);
        deviceList = JSON.parse(response.text);
        sidebar.postMessage("devices", deviceList);
        return deviceList;
    } catch (e) {
        console.log("Failed to fetch devices: " + e);
        return [];
    }
}

async function selectDevice(deviceId) {
    currentDevice = deviceList.find(d => d.id === deviceId);
    if (currentDevice) {
        sidebar.postMessage("selected", currentDevice.id);
    }
}

// ============================================================================
// Casting Control
// ============================================================================

async function startCasting() {
    if (!currentDevice) {
        core.osd("No device selected");
        return;
    }
    
    const mediaUrl = mpv.getString("path");
    const position = mpv.getNumber("time-pos") || 0;
    
    if (!mediaUrl) {
        core.osd("No media loaded");
        return;
    }
    
    core.osd(`Casting to ${currentDevice.name}...`);
    showCastOverlay();
    
    try {
        await http.post(`${HELPER_URL}/cast`, {
            body: JSON.stringify({
                deviceId: currentDevice.id,
                mediaUrl: mediaUrl,
                position: position
            }),
            headers: { "Content-Type": "application/json" }
        });
        
        castingActive = true;
        core.pause(); // Pause local playback
        core.osd(`Now casting to ${currentDevice.name}`);
        
    } catch (e) {
        console.log("Cast failed: " + e);
        core.osd("Failed to start casting");
        hideCastOverlay();
    }
}

async function stopCasting() {
    if (!castingActive) return;
    
    try {
        await http.post(`${HELPER_URL}/stop`);
        castingActive = false;
        currentDevice = null;
        hideCastOverlay();
        core.osd("Casting stopped");
    } catch (e) {
        console.log("Stop cast failed: " + e);
    }
}

async function sendControl(action, value) {
    if (!castingActive) return;
    
    try {
        await http.post(`${HELPER_URL}/control`, {
            body: JSON.stringify({ action, value }),
            headers: { "Content-Type": "application/json" }
        });
    } catch (e) {
        console.log(`Control ${action} failed: ` + e);
    }
}

// ============================================================================
// Position Synchronization
// ============================================================================

let lastSyncTime = 0;
const SYNC_INTERVAL = 1000; // ms

function throttledPositionSync() {
    const now = Date.now();
    if (now - lastSyncTime < SYNC_INTERVAL) return;
    lastSyncTime = now;
    
    if (castingActive) {
        const position = mpv.getNumber("time-pos");
        sendControl("seek", position);
    }
}

function syncPauseState() {
    if (castingActive) {
        const paused = mpv.getFlag("pause");
        sendControl(paused ? "pause" : "play");
    }
}

// ============================================================================
// UI: Overlay
// ============================================================================

function showCastOverlay() {
    overlay.simpleMode();
    overlay.setStyle(`
        #cast-indicator {
            position: fixed;
            top: 20px;
            right: 20px;
            background: rgba(0, 0, 0, 0.75);
            padding: 8px 14px;
            border-radius: 6px;
            display: flex;
            align-items: center;
            gap: 8px;
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            font-size: 13px;
            color: white;
            backdrop-filter: blur(10px);
            -webkit-backdrop-filter: blur(10px);
        }
        #cast-indicator .icon {
            font-size: 16px;
        }
        #cast-indicator .device-name {
            font-weight: 500;
        }
    `);
    updateCastOverlay();
    overlay.show();
}

function updateCastOverlay() {
    if (currentDevice) {
        overlay.setContent(`
            <div id="cast-indicator">
                <span class="icon">📺</span>
                <span class="device-name">${currentDevice.name}</span>
            </div>
        `);
    }
}

function hideCastOverlay() {
    overlay.hide();
}

// ============================================================================
// UI: Sidebar
// ============================================================================

sidebar.loadFile("ui/sidebar.html");

sidebar.onMessage("refresh", refreshDevices);
sidebar.onMessage("select", (data) => selectDevice(data.deviceId));
sidebar.onMessage("cast", startCasting);
sidebar.onMessage("stop", stopCasting);

// ============================================================================
// Event Handlers
// ============================================================================

// New file loaded
event.on("iina.file-loaded", () => {
    if (castingActive && currentDevice) {
        // Auto-cast new file
        startCasting();
    }
});

// Position changes (for sync)
event.on("mpv.time-pos.changed", throttledPositionSync);

// Pause state changes
event.on("mpv.pause.changed", syncPauseState);

// Window closing
event.on("iina.window-will-close", () => {
    if (castingActive) {
        stopCasting();
    }
});

// ============================================================================
// Hook: Intercept file load (optional advanced feature)
// ============================================================================

// Uncomment to intercept file loading for automatic casting
/*
mpv.addHook("on_load", 50, async (next) => {
    const url = mpv.getString("stream-open-filename");
    
    if (preferences.get("autoCast") && currentDevice) {
        await startCasting();
    }
    
    next();
});
*/

// ============================================================================
// Initialization
// ============================================================================

async function init() {
    console.log("IINA Cast plugin initialized");
    
    // Auto-discover devices on startup
    if (preferences.get("autoDiscovery")) {
        await refreshDevices();
    }
}

init();

// Export for sidebar communication
globalThis.castPlugin = {
    refreshDevices,
    selectDevice,
    startCasting,
    stopCasting,
    getDevices: () => deviceList,
    getCurrentDevice: () => currentDevice,
    isCasting: () => castingActive
};
