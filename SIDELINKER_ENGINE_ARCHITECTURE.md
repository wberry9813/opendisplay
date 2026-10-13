# SideLinker Direct Engine Runtime Architecture

Status: **DESIGN READY / IMPLEMENTATION BLOCKED ON INDEPENDENT REVIEW GATE**  
Task: **09 — Headless Engine Controller**  
Fork branch: `sidelinker/task09-headless-engine-controller`  
Identity baseline: `595ce69a2feda8eafb7ba2c310fcca2c366baa3d`

## 1. Goal

SideLinker should feel like one product to the user while the Direct Display implementation remains a separate GPL process.

The intended runtime is:

```text
Proprietary SideLinker Mac
  - UI / entitlement / automation
  - DisplayCoordinator / backend policy
  - starts and supervises Direct engine
              |
              | local control/status IPC only
              | no media frames
              v
GPL SideLinker Direct Engine
  - receiver discovery
  - virtual display
  - ScreenCaptureKit
  - VideoToolbox
  - usbmuxd / Wi-Fi transport
  - input return path
              |
              | existing OpenDisplay media/control protocol
              |
       +------+------+
       |             |
     USB           Wi-Fi
   usbmuxd      Bonjour + TCP
       |             |
       +------+------+
              v
GPL SideLinker Direct Receiver
        on iPad / iPhone / Mac
```

The user should normally interact only with SideLinker. The separate Direct engine is an implementation detail.

## 2. Process model

### SideLinker Mac is the product owner

The proprietary SideLinker Mac app owns:

- whether Direct Display is available to the user;
- Pro entitlement;
- Native vs Direct backend choice;
- preferred receiver/product policy;
- retry/cooldown/fallback policy;
- UI and user-visible status;
- whether the Direct engine should be running.

### SideLinker Direct is a separate process

The OpenDisplay-derived GPL process owns:

- low-level receiver discovery;
- Direct session mechanics;
- virtual display lifecycle;
- capture / encode / transport;
- sender/receiver wire protocol;
- input injection;
- Direct-specific permission/runtime diagnostics.

It must not import or depend on SideLinker product code.

## 3. Launch behavior

The product model is:

1. User launches SideLinker Mac.
2. SideLinker decides whether Direct capability should be activated.
3. If the Direct engine is not running, SideLinker starts it.
4. SideLinker establishes the local control connection.
5. The engine reports capabilities, permissions and receiver snapshots.
6. SideLinker decides when to start/stop a Direct session.
7. The engine performs the complete display/media operation independently.

The engine does **not** need to start unconditionally at every SideLinker launch. Product policy may choose:

- eager launch when Direct is enabled; or
- lazy launch when Direct discovery/session is first needed.

That choice remains proprietary SideLinker policy.

### Initial implementation shape

Task 09 should prefer reusing the existing signed **SideLinker Direct Mac target identity** and adding a headless engine mode instead of inventing another bundle/signing identity.

Conceptually:

```text
SideLinker Direct.app/Contents/MacOS/<executable> --engine ...
```

The headless mode must not show the upstream-style picker/control UI.

This keeps Screen Recording / Accessibility TCC identity stable while allowing the existing standalone UI mode to remain useful for fork development.

Final installer/helper packaging is a later guarded task.

## 4. SideLinker <-> engine IPC

### Chosen Task 09 transport: local Unix domain socket

For the first production-shaped control seam, use an **AF_UNIX local socket** rather than localhost TCP.

Reasons:

- cannot accidentally expose the engine control API on LAN;
- no TCP port ownership/collision;
- clear same-Mac process boundary;
- low overhead for small control messages;
- filesystem permissions can restrict access;
- independent of Swift/XPC ABI and app embedding;
- keeps the GPL executable visibly separate from proprietary SideLinker.

Recommended runtime location:

```text
~/Library/Application Support/SideLinker/Direct/engine.sock
```

Requirements:

- containing directory owner-only (`0700`);
- socket owner-only where practical;
- stale socket cleanup on engine startup;
- only one product-control owner in protocol v1;
- verify same-user peer credentials when the chosen socket implementation exposes them.

### Why not localhost TCP for SideLinker <-> engine

TCP is already correct for **engine <-> receiver** media transport.

Using TCP for the local product control channel adds network exposure/port concerns without providing a benefit. The local IPC should therefore be Unix-domain for Task 09.

### Why not XPC yet

XPC remains a possible future packaging/lifecycle mechanism, but Task 09 should not couple the architecture to an embedded XPC service before packaging, signing and GPL distribution boundaries are reviewed.

The **control protocol semantics must remain transport-neutral** enough that a later transport change does not alter SideLinker product behavior.

## 5. Control protocol v1

The local protocol is completely separate from the OpenDisplay sender/receiver protocol.

### Framing

Use:

```text
[4-byte unsigned big-endian JSON length][UTF-8 JSON object]
```

Rules:

- protocol version: `1`;
- maximum control frame: 256 KiB;
- one JSON object per frame;
- no video/audio/image payloads;
- unknown optional fields are ignored;
- unsupported methods return a structured error instead of closing the connection.

### Envelope

Request:

```json
{
  "v": 1,
  "kind": "request",
  "id": "request-id",
  "method": "startSession",
  "params": {}
}
```

Response:

```json
{
  "v": 1,
  "kind": "response",
  "id": "request-id",
  "ok": true,
  "result": {}
}
```

Event:

```json
{
  "v": 1,
  "kind": "event",
  "event": "receiverSnapshot",
  "payload": {}
}
```

## 6. Required commands

Protocol v1 should expose only the minimum useful surface.

### `hello`

Must be the first request.

Returns:

- control protocol version;
- engine build/version;
- supported capabilities;
- engine instance ID;
- supported Direct modes/transports.

### `listReceivers`

Returns the engine's current deduplicated receiver snapshot.

### `subscribe`

Subscribes the client to state/event snapshots.

### `startSession`

Minimum parameters:

- `receiverID`;
- `mode` — Task 09 only needs `extend`;
- `transportPreference` — `auto | usb | wifi`;
- optional bounded quality/display option only when already represented by the engine.

SideLinker chooses **which receiver/when**. The engine chooses low-level connection mechanics.

### `stopSession`

Stops the product-managed Direct session and destroys its Direct virtual display/runtime resources.

### `shutdown`

Graceful engine termination when SideLinker owns the launched instance.

The engine must tear down active sessions before exit.

## 7. Required events/state

### `engineState`

Values:

- `starting`
- `idle`
- `discovering`
- `connecting`
- `streaming`
- `stopping`
- `failed`

### `receiverSnapshot`

Full snapshot, not incremental mutation, in protocol v1.

Per receiver:

- stable `receiverID`;
- display name;
- available transports;
- device kind;
- panel/capability metadata when known;
- compatibility status when known.

The engine owns USB/Wi-Fi deduplication.

### `sessionState`

Includes:

- session ID;
- receiver ID;
- active transport;
- lifecycle state;
- bounded stream/display status;
- retryable failure hint where applicable.

### `permissionState`

Includes:

- Screen Recording;
- Accessibility where input injection is enabled.

### `diagnostic`

Stable error code + bounded human detail.

Initial stable error families should include:

- `permission.screenRecording`
- `permission.accessibility`
- `receiver.notFound`
- `session.busy`
- `transport.unavailable`
- `protocol.incompatible`
- `engine.internal`

## 8. What must never cross this IPC

Do not send through the engine control protocol:

- raw or encoded video frames;
- OpenDisplay sender/receiver frame traffic;
- StoreKit state;
- CloudKit keys/messages;
- Native Sidecar objects;
- BetterDisplay state;
- BLE/Watch/LocalWeb internals;
- proprietary UI models;
- product fallback policy.

The media path is direct:

```text
Engine -> receiver
```

not:

```text
Engine -> SideLinker -> receiver
```

## 9. Engine controller extraction seam

Current `Mac/OpenSidecarMacApp.swift` mixes:

- receiver discovery;
- usbmux watcher state;
- session creation;
- reconnect policy;
- standalone UI/product behavior.

Task 09 should extract a reusable engine-facing controller without rewriting the mature media pipeline.

Preferred shape:

```text
DirectEngineController
  |
  +-- ReceiverDiscovery
  |     +-- Bonjour
  |     +-- UsbmuxDeviceWatcher
  |     +-- USB/Wi-Fi identity dedupe
  |
  +-- SessionRegistry
  |     +-- existing DeviceSession mechanics
  |     +-- existing MacSender
  |
  +-- EngineSnapshot / EngineEvent
  |
  +-- LocalControlServer (Unix socket)
```

The existing standalone Mac UI should become a **client/adaptor of the extracted controller**, not remain the only owner of discovery/session mechanics.

## 10. Upstream-preservation rule

Task 09 should preserve and reuse:

- `MacSender`;
- `VirtualDisplay`;
- `StreamConfiguration`;
- `Usbmux`;
- `InputInjector`;
- `Shared/Protocol.swift`;
- receiver media/decode/render path.

Do not rewrite those components merely to fit the new control API.

Prefer moving orchestration into new files and making small call-site adaptations.

## 11. Session cardinality

Upstream OpenDisplay currently supports multiple sessions.

Task 09 must **not destroy that internal capability**, but SideLinker control protocol v1 may expose only **one product-managed active Direct session**.

This keeps the first SideLinker backend contract simple while avoiding an upstream-hostile refactor.

Future multi-display product support can widen the control contract additively.

## 12. Failure / ownership behavior

- SideLinker losing the control socket must not leave an unmanaged virtual display indefinitely.
- Engine should associate the active product-managed session with the control owner.
- On clean SideLinker shutdown: `shutdown` -> session teardown -> engine exit.
- On unexpected SideLinker death/control disconnect: engine performs bounded cleanup and exits unless a later product requirement explicitly allows persistence.
- On engine crash: SideLinker reports Direct unavailable and may apply bounded product retry policy.
- Engine internal reconnects to the receiver remain engine-owned and should not require SideLinker to replay media-layer operations.

## 13. Receiver transport remains OpenDisplay-derived

### Wi-Fi

```text
Receiver advertises _sidelinkerdirect._tcp
        ↓
Engine Bonjour discovery
        ↓
Engine opens TCP connection to receiver
        ↓
OpenDisplay protocol v3
```

### USB

```text
Engine -> /var/run/usbmuxd
       -> Connect(receiver port 9000)
       -> transparent TCP byte stream
       -> OpenDisplay protocol v3
```

SideLinker itself never owns this media connection.

## 14. Licensing/process boundary

This document records an engineering architecture, not a legal conclusion.

The intended boundary is:

- proprietary SideLinker: product orchestration;
- GPL SideLinker Direct: OpenDisplay-derived implementation;
- explicit local IPC between separate processes;
- no GPL implementation source copied into SideLinker-Source.

Packaging/distribution/source-offer obligations still require explicit later review.

## 15. Task 09 gate

Identity Bootstrap is complete at `595ce69a2feda8eafb7ba2c310fcca2c366baa3d`.

Before substantive engine extraction begins, the existing independent architecture/license-boundary review gate must pass.

Until then, Task 09 is **design/documentation only**.
