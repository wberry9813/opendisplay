# SideLinker Direct Local Control Protocol v1

Status: **DRAFT CONTRACT FOR TASK 09**  
Transport for Task 09: **local Unix domain stream socket**  
Media transport: **out of scope — remains OpenDisplay sender/receiver protocol**

## Principles

1. This protocol controls the Direct engine; it does not carry media.
2. SideLinker owns product policy; engine owns Direct mechanics.
3. Requests are idempotent where practical.
4. State snapshots are preferred over fragile mutation streams.
5. Unknown optional fields must be ignored.
6. Protocol additions should be backward-compatible within major version 1.

## Framing

Every message is:

```text
UInt32 big-endian payloadLength
UTF-8 JSON payload
```

Maximum payload: **262144 bytes**.

A zero-length frame or frame above the maximum is a protocol error.

## Common envelope

Every payload contains:

- `v`: integer protocol major, currently `1`;
- `kind`: `request | response | event`.

Requests also contain:

- `id`: caller-generated non-empty string;
- `method`;
- optional `params`.

Responses contain the same `id` and:

- `ok: true` plus optional `result`; or
- `ok: false` plus `error`.

Events contain:

- `event`;
- `payload`.

## Handshake

The first request must be `hello`.

Example:

```json
{"v":1,"kind":"request","id":"1","method":"hello","params":{"client":"SideLinker","clientVersion":"1.1.0"}}
```

Successful result includes:

```json
{
  "protocolVersion": 1,
  "engineVersion": "0.0.0",
  "engineInstanceID": "uuid",
  "capabilities": {
    "receiverDiscovery": true,
    "usb": true,
    "wifi": true,
    "extend": true,
    "input": true
  }
}
```

A protocol-major mismatch returns `protocol.incompatible`.

## Receiver model

A receiver snapshot entry has this minimum shape:

```json
{
  "receiverID": "stable-engine-id",
  "name": "iPad",
  "deviceKind": "iPad",
  "transports": ["usb","wifi"],
  "compatible": true
}
```

Optional additive fields may include panel facts, protocol version and codec capability summaries.

`receiverID` is engine-defined and must remain stable enough for one install/device identity across USB and Wi-Fi when upstream identity evidence permits.

## Methods

### hello

Mandatory first method.

### subscribe

Parameters:

```json
{"events":["engineState","receiverSnapshot","sessionState","permissionState","diagnostic"]}
```

Protocol v1 may treat this as subscribe-to-all if event filtering is not yet useful.

### listReceivers

No required parameters.

Returns a complete receiver array.

### startSession

```json
{
  "receiverID": "...",
  "mode": "extend",
  "transportPreference": "auto"
}
```

Allowed transport preference:

- `auto`
- `usb`
- `wifi`

Protocol v1 exposes one SideLinker-managed active Direct session.

Starting the already-active identical session should return its current state rather than create a duplicate.

Starting a different session while one product-managed session is active returns `session.busy` unless the existing session is explicitly stopped.

### stopSession

Parameters may include the current `sessionID`.

Repeated stop of an already-stopped session should succeed idempotently.

### shutdown

Requests graceful session cleanup and engine exit.

Only accepted from the current control owner.

## Events

### engineState

```json
{"state":"idle"}
```

### receiverSnapshot

```json
{"receivers":[]}
```

Always represents a full current snapshot.

### sessionState

```json
{
  "sessionID": "...",
  "receiverID": "...",
  "state": "streaming",
  "transport": "usb"
}
```

### permissionState

```json
{
  "screenRecording": "granted",
  "accessibility": "unknown"
}
```

Allowed permission values should be a small stable enum such as:

- `granted`
- `denied`
- `notDetermined`
- `unknown`

### diagnostic

```json
{
  "code": "transport.unavailable",
  "message": "USB receiver is no longer attached",
  "retryable": true
}
```

Messages are for diagnostics/UI hints, not stable program logic. SideLinker logic must key on `code`.

## Error object

```json
{
  "code": "receiver.notFound",
  "message": "Receiver is no longer available",
  "retryable": true
}
```

Initial error codes:

- `protocol.invalidFrame`
- `protocol.invalidMessage`
- `protocol.incompatible`
- `permission.screenRecording`
- `permission.accessibility`
- `receiver.notFound`
- `session.busy`
- `session.notFound`
- `transport.unavailable`
- `engine.internal`

## Ordering

Within one control connection:

- responses correspond to request IDs;
- events are ordered as emitted by the engine;
- a fresh `receiverSnapshot` supersedes prior receiver snapshots;
- a fresh `sessionState` supersedes prior state for the same session.

SideLinker must tolerate receiving state events immediately after subscription and before its explicit `listReceivers` response.

## Connection ownership

Protocol v1 supports one controlling SideLinker client.

A second client must not silently take over an active product-managed session.

The engine should either reject it with `control.ownerExists` or expose it read-only in a later protocol revision.

## Security boundary

The control listener must not bind a TCP/LAN endpoint.

For Unix socket deployment:

- parent directory is user-private;
- stale socket is removed safely only after ownership/path checks;
- peer must be same local user when peer credentials are available;
- no secrets from StoreKit/CloudKit are required by this protocol.

## Explicit non-goals

Protocol v1 does not:

- carry video;
- carry OpenDisplay protocol frames;
- expose raw NWConnection/NWBrowser objects;
- expose usbmux DeviceID as product identity;
- define SideLinker backend fallback;
- define StoreKit entitlement;
- define receiver App Store packaging;
- define final installer/update mechanism.
