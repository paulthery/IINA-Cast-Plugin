# Protocol Implementation Reference

Complete technical reference for Chromecast CASTV2 and DLNA/UPNP protocols.

---

## Chromecast CASTV2 Protocol

### Overview

CASTV2 is Google's proprietary protocol for Chromecast communication. It uses:
- **Transport**: TLS over TCP port 8009
- **Framing**: Length-prefixed Protocol Buffers
- **Messaging**: JSON payloads within protobuf wrapper
- **Channels**: Namespace-based virtual connections

### Discovery (mDNS/DNS-SD)

Service type: `_googlecast._tcp.local`

TXT record fields:
| Field | Description | Example |
|-------|-------------|---------|
| `id` | Device UUID | `aabbccdd-1234-...` |
| `fn` | Friendly name | `Living Room TV` |
| `md` | Model name | `Chromecast Ultra` |
| `rs` | Running app state | `Netflix` |
| `ca` | Capabilities bitmap | `201221` |
| `ve` | Version | `05` |

Swift implementation with Network.framework:
```swift
import Network

class ChromecastDiscovery {
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]
    
    func startDiscovery(onFound: @escaping (ChromecastDevice) -> Void) {
        let params = NWParameters()
        params.includePeerToPeer = true
        
        browser = NWBrowser(
            for: .bonjour(type: "_googlecast._tcp", domain: "local"),
            using: params
        )
        
        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            for result in results {
                self?.resolveDevice(result: result, onResolved: onFound)
            }
        }
        
        browser?.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("Browser failed: \(error)")
            }
        }
        
        browser?.start(queue: .main)
    }
    
    private func resolveDevice(result: NWBrowser.Result, onResolved: @escaping (ChromecastDevice) -> Void) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }
        
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                // Extract IP from resolved endpoint
                if let path = connection.currentPath,
                   case .hostPort(let host, _) = path.remoteEndpoint {
                    let device = ChromecastDevice(
                        id: name,
                        name: self?.extractTXTField(result, "fn") ?? name,
                        host: "\(host)",
                        port: 8009,
                        model: self?.extractTXTField(result, "md") ?? "Chromecast"
                    )
                    onResolved(device)
                }
                connection.cancel()
            }
        }
        connection.start(queue: .main)
        connections[name] = connection
    }
}
```

### Connection Establishment

1. **TCP Connect** to device IP:8009
2. **TLS Handshake** (accept self-signed cert)
3. **Send CONNECT** to connection namespace
4. **Start heartbeat** (PING every 5s)
5. **Launch receiver app**
6. **Connect to media namespace**

### Message Framing

Each message is framed as:
```
[4 bytes: payload length (big-endian)] [N bytes: protobuf payload]
```

Protobuf schema (simplified):
```protobuf
message CastMessage {
  required string source_id = 1;      // "sender-0"
  required string destination_id = 2;  // "receiver-0" or session transport ID
  required string namespace = 3;       // e.g., "urn:x-cast:com.google.cast.media"
  required PayloadType payload_type = 4;
  optional string payload_utf8 = 5;    // JSON string
  optional bytes payload_binary = 6;
}

enum PayloadType {
  STRING = 0;
  BINARY = 1;
}
```

### Namespaces and Messages

#### Connection Channel
Namespace: `urn:x-cast:com.google.cast.tp.connection`

```json
// Connect to device
{"type": "CONNECT", "origin": {}}

// Close connection
{"type": "CLOSE"}
```

#### Heartbeat Channel
Namespace: `urn:x-cast:com.google.cast.tp.heartbeat`

```json
// Ping (send every 5 seconds)
{"type": "PING"}

// Pong (response)
{"type": "PONG"}
```

#### Receiver Channel
Namespace: `urn:x-cast:com.google.cast.receiver`

```json
// Launch Default Media Receiver
{
  "type": "LAUNCH",
  "appId": "CC1AD845",
  "requestId": 1
}

// Response
{
  "type": "RECEIVER_STATUS",
  "requestId": 1,
  "status": {
    "applications": [{
      "appId": "CC1AD845",
      "displayName": "Default Media Receiver",
      "sessionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "transportId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    }],
    "volume": {
      "level": 1.0,
      "muted": false
    }
  }
}

// Set volume
{
  "type": "SET_VOLUME",
  "volume": { "level": 0.5 },
  "requestId": 2
}
```

#### Media Channel
Namespace: `urn:x-cast:com.google.cast.media`

**LOAD (start playback)**
```json
{
  "type": "LOAD",
  "requestId": 1,
  "media": {
    "contentId": "http://192.168.1.100:9877/media/stream/abc123",
    "contentType": "video/mp4",
    "streamType": "BUFFERED",
    "duration": 7200.5,
    "metadata": {
      "metadataType": 1,
      "title": "Movie Title",
      "subtitle": "2024",
      "images": [{
        "url": "http://192.168.1.100:9877/thumb/abc123.jpg"
      }]
    },
    "tracks": [{
      "trackId": 1,
      "type": "TEXT",
      "trackContentId": "http://192.168.1.100:9877/subtitles/abc123.vtt",
      "trackContentType": "text/vtt",
      "subtype": "SUBTITLES",
      "name": "French",
      "language": "fr"
    }],
    "textTrackStyle": {
      "backgroundColor": "#00000000",
      "foregroundColor": "#FFFFFFFF",
      "fontScale": 1.0,
      "fontFamily": "sans-serif"
    }
  },
  "autoplay": true,
  "currentTime": 0,
  "activeTrackIds": [1]
}
```

**PLAY/PAUSE/STOP**
```json
{"type": "PLAY", "requestId": 2, "mediaSessionId": 1}
{"type": "PAUSE", "requestId": 3, "mediaSessionId": 1}
{"type": "STOP", "requestId": 4, "mediaSessionId": 1}
```

**SEEK**
```json
{
  "type": "SEEK",
  "requestId": 5,
  "mediaSessionId": 1,
  "currentTime": 120.0,
  "resumeState": "PLAYBACK_START"
}
```

**GET_STATUS**
```json
{"type": "GET_STATUS", "requestId": 6, "mediaSessionId": 1}
```

**MEDIA_STATUS (event/response)**
```json
{
  "type": "MEDIA_STATUS",
  "status": [{
    "mediaSessionId": 1,
    "playbackRate": 1,
    "playerState": "PLAYING",
    "currentTime": 42.5,
    "supportedMediaCommands": 274447,
    "volume": {"level": 1, "muted": false},
    "media": {...},
    "currentItemId": 1,
    "idleReason": null
  }],
  "requestId": 6
}
```

### Player States

| State | Description |
|-------|-------------|
| `IDLE` | No media loaded |
| `BUFFERING` | Loading/buffering content |
| `PLAYING` | Active playback |
| `PAUSED` | Paused |

### Idle Reasons

| Reason | Description |
|--------|-------------|
| `CANCELLED` | User stopped |
| `INTERRUPTED` | Another app launched |
| `FINISHED` | Playback complete |
| `ERROR` | Playback error |

### Error Handling

Media errors are reported via MEDIA_STATUS with `idleReason: "ERROR"`:
```json
{
  "type": "MEDIA_STATUS",
  "status": [{
    "playerState": "IDLE",
    "idleReason": "ERROR",
    "extendedStatus": {
      "playerState": "LOADING",
      "media": {...}
    }
  }]
}
```

Common errors:
- Network unreachable (check firewall)
- Unsupported format (need transcode)
- DRM content (not supported)

---

## DLNA/UPNP Protocol

### Overview

DLNA uses UPnP (Universal Plug and Play) for device discovery and control:
- **Discovery**: SSDP (Simple Service Discovery Protocol)
- **Description**: HTTP GET XML
- **Control**: SOAP over HTTP
- **Eventing**: GENA (optional)

### SSDP Discovery

#### M-SEARCH Request

Send to multicast address `239.255.255.250:1900`:

```http
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 3
ST: urn:schemas-upnp-org:device:MediaRenderer:1
USER-AGENT: IINA-Cast/1.0 UPnP/1.1

```

Note: Must end with blank line (`\r\n\r\n`).

#### M-SEARCH Response

```http
HTTP/1.1 200 OK
CACHE-CONTROL: max-age=1800
DATE: Sun, 28 Dec 2025 14:00:00 GMT
EXT:
LOCATION: http://192.168.1.50:52235/description.xml
SERVER: Linux/4.x UPnP/1.0 Samsung TV/1.0
ST: urn:schemas-upnp-org:device:MediaRenderer:1
USN: uuid:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx::urn:schemas-upnp-org:device:MediaRenderer:1

```

#### Swift SSDP Implementation

```swift
import CocoaAsyncSocket

class SSDPDiscovery: NSObject, GCDAsyncUdpSocketDelegate {
    private var socket: GCDAsyncUdpSocket?
    private let multicastGroup = "239.255.255.250"
    private let multicastPort: UInt16 = 1900
    
    var onDeviceFound: ((String, URL) -> Void)?
    
    func startDiscovery() throws {
        socket = GCDAsyncUdpSocket(delegate: self, delegateQueue: .main)
        try socket?.enableReusePort(true)
        try socket?.bind(toPort: 0)
        try socket?.joinMulticastGroup(multicastGroup)
        try socket?.beginReceiving()
        
        sendMSearch()
    }
    
    private func sendMSearch() {
        let query = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 3\r
        ST: urn:schemas-upnp-org:device:MediaRenderer:1\r
        USER-AGENT: IINA-Cast/1.0 UPnP/1.1\r
        \r
        
        """
        
        let data = query.data(using: .utf8)!
        socket?.send(data, toHost: multicastGroup, port: multicastPort, withTimeout: -1, tag: 0)
    }
    
    func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        guard let response = String(data: data, encoding: .utf8) else { return }
        
        // Parse LOCATION header
        if let locationRange = response.range(of: "LOCATION: "),
           let endRange = response.range(of: "\r\n", range: locationRange.upperBound..<response.endIndex),
           let url = URL(string: String(response[locationRange.upperBound..<endRange.lowerBound])) {
            
            // Parse USN for device ID
            if let usnRange = response.range(of: "USN: uuid:"),
               let usnEnd = response.range(of: "::", range: usnRange.upperBound..<response.endIndex) {
                let deviceId = String(response[usnRange.upperBound..<usnEnd.lowerBound])
                onDeviceFound?(deviceId, url)
            }
        }
    }
}
```

### Device Description

Fetch XML from LOCATION URL:

```xml
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion>
    <major>1</major>
    <minor>0</minor>
  </specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>[TV]Samsung 2017</friendlyName>
    <manufacturer>Samsung Electronics</manufacturer>
    <modelName>UE55MU7000</modelName>
    <UDN>uuid:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/AVTransport/control</controlURL>
        <eventSubURL>/AVTransport/event</eventSubURL>
        <SCPDURL>/AVTransport/scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/RenderingControl/control</controlURL>
        <eventSubURL>/RenderingControl/event</eventSubURL>
        <SCPDURL>/RenderingControl/scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
        <controlURL>/ConnectionManager/control</controlURL>
        <eventSubURL>/ConnectionManager/event</eventSubURL>
        <SCPDURL>/ConnectionManager/scpd.xml</SCPDURL>
      </service>
    </serviceList>
  </device>
</root>
```

### SOAP Control

#### Generic SOAP Request

```http
POST /AVTransport/control HTTP/1.1
Host: 192.168.1.50:52235
Content-Type: text/xml; charset="utf-8"
Content-Length: <length>
SOAPACTION: "urn:schemas-upnp-org:service:AVTransport:1#<ActionName>"

<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" 
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:<ActionName> xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <!-- Action-specific arguments -->
    </u:<ActionName>>
  </s:Body>
</s:Envelope>
```

#### SetAVTransportURI (Load Media)

```xml
<u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
  <InstanceID>0</InstanceID>
  <CurrentURI>http://192.168.1.100:9877/media/stream/abc123.mp4</CurrentURI>
  <CurrentURIMetaData>
    &lt;DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" 
               xmlns:dc="http://purl.org/dc/elements/1.1/" 
               xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"&gt;
      &lt;item id="0" parentID="-1" restricted="1"&gt;
        &lt;dc:title&gt;Movie Title&lt;/dc:title&gt;
        &lt;upnp:class&gt;object.item.videoItem.movie&lt;/upnp:class&gt;
        &lt;res protocolInfo="http-get:*:video/mp4:DLNA.ORG_PN=AVC_MP4_HP_HD_AAC;DLNA.ORG_FLAGS=01700000000000000000000000000000"&gt;
          http://192.168.1.100:9877/media/stream/abc123.mp4
        &lt;/res&gt;
      &lt;/item&gt;
    &lt;/DIDL-Lite&gt;
  </CurrentURIMetaData>
</u:SetAVTransportURI>
```

Note: `CurrentURIMetaData` must be XML-escaped.

#### Play

```xml
<u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
  <InstanceID>0</InstanceID>
  <Speed>1</Speed>
</u:Play>
```

#### Pause

```xml
<u:Pause xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
  <InstanceID>0</InstanceID>
</u:Pause>
```

#### Stop

```xml
<u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
  <InstanceID>0</InstanceID>
</u:Stop>
```

#### Seek

```xml
<u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
  <InstanceID>0</InstanceID>
  <Unit>REL_TIME</Unit>
  <Target>01:30:45</Target>
</u:Seek>
```

Time format: `HH:MM:SS` or `HH:MM:SS.mmm`

#### GetPositionInfo

Request:
```xml
<u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
  <InstanceID>0</InstanceID>
</u:GetPositionInfo>
```

Response:
```xml
<u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
  <Track>1</Track>
  <TrackDuration>02:00:00</TrackDuration>
  <TrackMetaData>...</TrackMetaData>
  <TrackURI>http://...</TrackURI>
  <RelTime>00:42:30</RelTime>
  <AbsTime>00:42:30</AbsTime>
  <RelCount>2147483647</RelCount>
  <AbsCount>2147483647</AbsCount>
</u:GetPositionInfoResponse>
```

#### GetTransportInfo

Request:
```xml
<u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
  <InstanceID>0</InstanceID>
</u:GetTransportInfo>
```

Response:
```xml
<u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
  <CurrentTransportState>PLAYING</CurrentTransportState>
  <CurrentTransportStatus>OK</CurrentTransportStatus>
  <CurrentSpeed>1</CurrentSpeed>
</u:GetTransportInfoResponse>
```

Transport states: `STOPPED`, `PLAYING`, `PAUSED_PLAYBACK`, `TRANSITIONING`, `NO_MEDIA_PRESENT`

### RenderingControl (Volume)

#### SetVolume

```xml
<u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
  <InstanceID>0</InstanceID>
  <Channel>Master</Channel>
  <DesiredVolume>50</DesiredVolume>
</u:SetVolume>
```

Volume range: 0-100 (device-dependent)

#### GetVolume

```xml
<u:GetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
  <InstanceID>0</InstanceID>
  <Channel>Master</Channel>
</u:GetVolume>
```

#### SetMute

```xml
<u:SetMute xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
  <InstanceID>0</InstanceID>
  <Channel>Master</Channel>
  <DesiredMute>1</DesiredMute>
</u:SetMute>
```

### DIDL-Lite Metadata

Full DIDL-Lite example for video:

```xml
<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
           xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"
           xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/"
           xmlns:sec="http://www.sec.co.kr/">
  <item id="0" parentID="-1" restricted="1">
    <dc:title>Movie Title</dc:title>
    <dc:creator>Director Name</dc:creator>
    <upnp:class>object.item.videoItem.movie</upnp:class>
    <upnp:genre>Action</upnp:genre>
    <res protocolInfo="http-get:*:video/x-matroska:DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000"
         size="53687091200"
         duration="2:00:00.000"
         resolution="3840x2160"
         bitrate="5961232">
      http://192.168.1.100:9877/media/stream/abc123.mkv
    </res>
    <upnp:albumArtURI>http://192.168.1.100:9877/thumb/abc123.jpg</upnp:albumArtURI>
  </item>
</DIDL-Lite>
```

### DLNA Protocol Info

Format: `<protocol>:<network>:<contentFormat>:<additionalInfo>`

Example: `http-get:*:video/mp4:DLNA.ORG_PN=AVC_MP4_HP_HD_AAC;DLNA.ORG_FLAGS=01700000000000000000000000000000`

Common DLNA.ORG_PN values:
| Profile | Description |
|---------|-------------|
| `AVC_MP4_HP_HD_AAC` | H.264 High Profile + AAC in MP4 |
| `AVC_MKV_HP_HD_AAC` | H.264 High Profile + AAC in MKV |
| `HEVC_MP4_UHD` | HEVC in MP4 (DLNA 3.0) |
| `AVC_TS_HD_50_AC3` | H.264 + AC3 in MPEG-TS |

DLNA.ORG_FLAGS (32 hex chars):
- Bit 24: Sender paced (0)
- Bit 23: Time-based seek (1)
- Bit 22: Byte-based seek (1)
- Bit 21: Play container (1)
- Bit 20: S0 increasing (0)
- ... etc.

Common flag value: `01700000000000000000000000000000`

### Error Handling

SOAP faults:
```xml
<s:Fault>
  <faultcode>s:Client</faultcode>
  <faultstring>UPnPError</faultstring>
  <detail>
    <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
      <errorCode>716</errorCode>
      <errorDescription>Resource not found</errorDescription>
    </UPnPError>
  </detail>
</s:Fault>
```

Common error codes:
| Code | Description |
|------|-------------|
| 401 | Invalid Action |
| 402 | Invalid Args |
| 501 | Action Failed |
| 716 | Resource Not Found |
| 718 | Invalid InstanceID |

---

## Protocol Selection Logic

```swift
func selectProtocol(for device: CastDevice, media: MediaInfo) -> CastProtocol {
    switch device.type {
    case .chromecast:
        // Chromecast requires MP4 container
        if media.container != "mp4" {
            return .chromecast(needsRemux: true)
        }
        return .chromecast(needsRemux: false)
        
    case .dlna:
        // DLNA is more permissive with containers
        // But some devices have quirks
        return .dlna(profile: detectDLNAProfile(media))
    }
}
```
