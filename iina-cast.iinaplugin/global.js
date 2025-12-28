/**
 * IINA Cast Plugin - Global Entry
 * This runs once when IINA starts (not per-window)
 * Used for helper process lifecycle management
 */

const { global, utils, http, file, preferences, console } = iina;

// Configuration
const HELPER_PORT = preferences.get("helperPort") || 9876;
const HELPER_URL = `http://localhost:${HELPER_PORT}`;
const HELPER_BINARY = "@data/bin/iina-cast-helper";
const HELPER_DOWNLOAD_URL = "https://github.com/yourusername/IINA-Cast-Plugin/releases/latest/download/iina-cast-helper-macos";

let helperProcess = null;
let helperRunning = false;

// ============================================================================
// Helper Binary Management
// ============================================================================

async function ensureHelperExists() {
    if (file.exists(HELPER_BINARY)) {
        console.log("Helper binary found");
        return true;
    }
    
    console.log("Downloading helper binary...");
    
    try {
        // Create bin directory if needed
        const binDir = "@data/bin";
        if (!file.exists(binDir)) {
            await utils.exec("mkdir", ["-p", file.resolvePath(binDir)]);
        }
        
        // Download helper
        await http.download(HELPER_DOWNLOAD_URL, HELPER_BINARY);
        
        // Make executable
        await utils.exec("chmod", ["+x", file.resolvePath(HELPER_BINARY)]);
        
        console.log("Helper binary downloaded and ready");
        return true;
        
    } catch (e) {
        console.log("Failed to download helper: " + e);
        return false;
    }
}

async function isHelperRunning() {
    try {
        const response = await http.get(`${HELPER_URL}/health`);
        return response.status === 200;
    } catch (e) {
        return false;
    }
}

async function startHelper() {
    if (await isHelperRunning()) {
        console.log("Helper already running");
        helperRunning = true;
        return true;
    }
    
    if (!await ensureHelperExists()) {
        console.log("Helper binary not available");
        return false;
    }
    
    console.log("Starting helper process...");
    
    try {
        // Start helper as daemon
        await utils.exec(file.resolvePath(HELPER_BINARY), [
            "--port", String(HELPER_PORT),
            "--daemon"
        ]);
        
        // Wait for helper to be ready
        for (let i = 0; i < 10; i++) {
            await new Promise(resolve => setTimeout(resolve, 500));
            if (await isHelperRunning()) {
                console.log("Helper started successfully");
                helperRunning = true;
                return true;
            }
        }
        
        console.log("Helper failed to start (timeout)");
        return false;
        
    } catch (e) {
        console.log("Failed to start helper: " + e);
        return false;
    }
}

async function stopHelper() {
    if (!helperRunning) return;
    
    try {
        await http.post(`${HELPER_URL}/shutdown`);
        helperRunning = false;
        console.log("Helper stopped");
    } catch (e) {
        console.log("Failed to stop helper gracefully: " + e);
    }
}

// ============================================================================
// Lifecycle
// ============================================================================

async function init() {
    console.log("IINA Cast global entry initializing...");
    
    // Start helper on IINA launch
    const started = await startHelper();
    
    if (!started) {
        console.log("Warning: Cast helper not running. Casting will not work.");
    }
}

// Cleanup on IINA quit
global.onQuit(() => {
    stopHelper();
});

// ============================================================================
// Exported API for main.js instances
// ============================================================================

globalThis.castGlobal = {
    isHelperRunning: () => helperRunning,
    startHelper,
    stopHelper,
    getHelperUrl: () => HELPER_URL
};

// Start
init();
