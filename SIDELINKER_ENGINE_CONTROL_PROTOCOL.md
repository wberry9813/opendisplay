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

## Session grant semantics

Protocol v1 treats a successful `startSession` as an explicit **Direct session grant** from SideLinker.

Discovery by itself never creates such a grant.

While no grant exists, receiver/transport changes may generate `receiverSnapshot` events but must not start a new Direct display session.

While a grant exists, the engine may autonomously recover or migrate the already-authorized session using its existing low-level reconnect mechanics, subject to the requested transport preference.

A successful `stopSession` **revokes** the grant. After revocation, discovery, remembered-device state, Bonjour refreshes, USB attach events and stale reconnect timers must not resurrect the session.

A receiver-announced `closing` (the receiver deliberately ending the session — app quit, stop listening, or a session-only disconnect) is also **terminal**: the engine revokes the grant and does not recover it, and discovery or a still-attached USB entry must not reopen the screen. Accidental link loss (an unannounced disconnect, a network drop, or the receiver's `sleeping` lock path) keeps the existing recovery of the already-authorized grant.

Only a new `startSession` may authorize a new Direct session.

The engine protocol does not arbitrate Native Sidecar. SideLinker product policy is responsible for granting connection intent to only one backend at a time.

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

### Task20 prepared activation (development)

Control major/framing remain v1. `hello.capabilities.receiverPreflight` is the integer
`1`, not a boolean. Absence/other versions means unsupported; clients must not call
`startSession` or media9000 as a compatibility fallback.

- `prepareReceiver {receiverID, mode:"extend", transportPreference, requestContext}`:
  idle managed owner only; fresh lowercase UUID context; one pending/prepared operation
  per owner incarnation. Returns Engine-instance/context/probe/activation/receiver/epoch
  binding, a fresh opaque `preparedHandle`, actual transport, explicit PV/minimum facts,
  reported-compatible booleans and remaining `ttlMs` (at most3000). No grant or session.
- `cancelPreparedReceiver {engineInstanceID, requestContext}`: idempotent for that
  owner/context, replies `state:"cancelled"` only after matching holder I/O cleanup.
  If the matching context already committed, returns `state:"committed",session:{...}`
  with its exact sessionID/activationID, rather than claiming cancellation or stopping
  the session. The client must use targeted `stopSession` to release that session.
  A stale context cannot stop a replacement. Owner EOF/stop/shutdown retire pending
  preparation before existing grant teardown. Cancelling remains busy until cleanup.
- `activatePreparedReceiver {engineInstanceID,requestContext,preparedHandle}` consumes
  the matching owner's prepared handle atomically before asynchronous I/O. Repeats
  return `preflight.consumedOrUnknown`. It sends activate on the SAME prepared9002
  socket, requires the exact ACK tuple and a byte-identical strictly validated full
  hello before any grant/session/sender construction. Activation has a fixed3s
  deadline. Final main-authority checks include owner/instance/context, idle grant/
  generation, pinned route/DeviceID and permission. No second dial or9000 fallback.
  Result is the existing managed session snapshot plus `activationID`.
- Prepared sessions include that `activationID` in every subscribed `sessionState`,
  including stop events. Legacy sessions omit it. The context association lasts only
  for that active grant. Re-subscribe on the SAME control owner replays snapshots;
  lost response never authorizes retrying activate. Idle alone is not a cancellation
  barrier; use cancel and exactly correlate a committed result before targeted stop.

Receiver preflight v1 uses separate TCP9002, exact bounded length-prefixed JSON and
per-socket full-hello evidence. Bonjour `pf=1,pfp=9002` are locator hints, never proof.
Network resolution uses DNSServiceResolve/GetAddrInfo without media dialing; ambiguous
interfaces/routes fail closed. USB requires an existing unique install→attached exact
UDID mapping and matching current DeviceID. The preflight-only cancellable usbmux
operation owns each list/connect socket; legacy `Usbmux` media APIs/callers are unchanged.
Prepare has a fixed5s deadline; validated proof/socket has a nonrenewable3s lease.
No raw socket/endpoint/UDID/nonce or hello bytes cross Product IPC; no compatibility
fact is written back to discovery. This is version observation, not peer authentication.

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

### getDisplaySize

No required parameters. Only valid while a managed session grant exists.

Returns the engine-owned per-device display-size choice and the outcomes for every supported
choice. The engine owns HiDPI selection, stream reconfiguration, fallback and persistence;
SideLinker only projects these facts.

```json
{
  "sessionID": "...",
  "receiverID": "...",
  "choice": "default",
  "outcomes": [
    {
      "choice": "default",
      "pointsWide": 1280,
      "pointsHigh": 960,
      "scale": 2,
      "sentWidth": 2560,
      "sentHeight": 1920
    }
  ]
}
```

`choice` is one of `largerText`, `default`, `moreSpace`, `native`. `pointsWide/pointsHigh/scale`
describe the desktop the engine would run; `sentWidth/sentHeight` describe the encoded stream.

### setDisplaySize

Parameters:

```json
{"choice": "moreSpace"}
```

Only valid while a managed session grant exists and the receiver has supplied its display facts.
Returns the same snapshot as `getDisplaySize` after the engine stores the choice and schedules its
existing in-place live resize. A successful response means the engine accepted and persisted the
choice; it is not a claim that the receiver has already repainted the new raster.

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
- `displaySize.unavailable`
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
