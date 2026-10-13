# Task 09 — Headless Direct Engine Controller

Status: **DESIGN READY / IMPLEMENTATION BLOCKED ON INDEPENDENT REVIEW**  
Risk: **GUARDED / IMMEDIATE**  
Branch: `sidelinker/task09-headless-engine-controller`  
Starting checkpoint: `595ce69a2feda8eafb7ba2c310fcca2c366baa3d`  
Architecture: `SIDELINKER_ENGINE_ARCHITECTURE.md`  
Control contract: `SIDELINKER_ENGINE_CONTROL_PROTOCOL.md`

## Goal

Turn the current standalone OpenDisplay-derived Mac sender application into a reusable **headless Direct engine process** while preserving its mature display/media implementation.

Task 09 should establish:

- an engine controller independent from the existing Mac UI;
- receiver snapshots owned by the engine;
- product-managed session start/stop;
- a local Unix-domain control server implementing protocol v1;
- a headless engine launch mode;
- continued standalone fork UI functionality for development.

## Prerequisite gate

The SideLinker Task 07 independent architecture/license-boundary review is still required.

**No substantive Task 09 source implementation should begin until that review passes.**

Documentation/design work is allowed before that gate.

## Required architecture

```text
SideLinker Mac
   |
   | Unix domain socket
   | control/status JSON only
   v
SideLinker Direct Engine process
   |
   +-- Bonjour / usbmux discovery
   +-- MacSender
   +-- VirtualDisplay
   +-- ScreenCaptureKit
   +-- VideoToolbox
   |
   +---- USB/Wi-Fi ----> Direct Receiver
```

## Connection ownership requirement

Task 09 must explicitly separate **discovery** from **connection authority**.

Managed/headless engine mode:

- keeps Bonjour and usbmuxd discovery active;
- publishes receiver/transport snapshots;
- must not auto-create a session from USB attach, Bonjour discovery, remembered-device state or discovery refresh;
- creates a product-managed session only after `startSession`.

Once a SideLinker-authorized session exists, existing low-level OpenDisplay recovery/reconnect/transport-migration behavior may keep that same session alive.

After `stopSession`, the grant is revoked and no discovery/reconnect path may resurrect it.

The existing standalone development mode may retain upstream-style auto-connect behavior, but it must reuse the same extracted discovery/session mechanics through a standalone policy adaptor rather than duplicate the stack.

SideLinker product policy owns exclusive backend connection intent: Direct discovery may continue while Native is active, but no Direct session starts until SideLinker grants it.

## Implementation sequence after review PASS

### Phase A — extract engine-owned receiver/session model

Refactor discovery/session orchestration currently concentrated in `Mac/OpenSidecarMacApp.swift`.

Prefer additive files such as:

- `Mac/Engine/DirectEngineController.swift`
- `Mac/Engine/ReceiverSnapshot.swift`
- `Mac/Engine/EngineSessionState.swift`

The extracted controller should own:

- `NWBrowser` receiver discovery;
- `UsbmuxDeviceWatcher`;
- USB/Wi-Fi receiver identity correlation;
- the session registry;
- `MacSender` construction/lifecycle.

The SwiftUI/AppKit UI should observe/adapt this controller instead of owning these mechanics.

### Phase B — add headless engine mode

Reuse the existing SideLinker Direct Mac app identity.

Headless mode:

- no picker/control window;
- starts engine controller;
- starts local control server;
- emits no product policy;
- remains diagnosable via existing log mechanism.

Do not introduce another TCC identity unless a later explicit task requires it.

### Phase C — local control server

Implement `SIDELINKER_ENGINE_CONTROL_PROTOCOL.md` v1 over a local Unix domain socket.

Required methods/events:

- hello;
- subscribe;
- listReceivers;
- startSession;
- stopSession;
- shutdown;
- engineState;
- receiverSnapshot;
- sessionState;
- permissionState;
- diagnostic.

No media payloads.

### Phase D — preserve standalone development UI

The current Mac fork UI may remain available for upstream comparison and engine development.

It should call the extracted engine controller directly rather than maintain a second discovery/session implementation.

## Frozen implementation areas

Task 09 must not rewrite, except for minimal integration call-site changes:

- `Mac/MacSender.swift` media/capture/encode pipeline;
- `Mac/VirtualDisplay.swift` display mechanics;
- `Mac/StreamConfiguration.swift`;
- `Mac/Usbmux.swift` protocol implementation;
- `Mac/InputInjector.swift` mechanics;
- `Shared/Protocol.swift` sender/receiver wire semantics;
- `Shared/StreamReceiver.swift` receiver media protocol;
- iOS decode/render pipeline.

If one of these appears to require a material algorithm/protocol rewrite, stop and split a new guarded task.

## Explicitly out of scope

- proprietary SideLinker `DirectDisplayBackend`;
- changing SideLinker product fallback policy;
- final installer/helper packaging;
- final XPC decision;
- Sparkle/App Store release setup;
- GPL distribution/source-offer finalization;
- new media protocol;
- audio;
- authentication/encryption of the OpenDisplay media protocol;
- multi-display product UX.

## Compatibility requirements

- preserve OpenDisplay protocol v3 sender/receiver behavior;
- preserve USB via usbmuxd;
- preserve Wi-Fi media via Bonjour + TCP;
- preserve current receiver install-ID correlation where available;
- preserve rotation/rebuild/keyframe/reconnect behavior;
- preserve current TCC bundle identity established by Task 08;
- do not restore upstream OpenDisplay update/distribution identities.

## Verification after implementation

Minimum writer verification:

1. project generation succeeds;
2. Mac unit tests pass;
3. standalone Mac sender UI still builds;
4. headless engine mode builds;
5. protocol framing/parser synthetic tests pass;
6. receiver snapshot dedupe tests pass;
7. start/stop lifecycle synthetic tests pass;
8. managed-mode discovery cannot auto-start a session;
9. `stopSession` prevents USB/Bonjour/reconnect resurrection;
10. authorized-session reconnect remains functional;
11. frozen media-core diff is inspected and justified;
12. no localhost/LAN control listener exists;
13. `git diff --check` passes.

Runtime gate after source verification:

1. signed Debug engine launches with stable Task 08 identity;
2. SideLinker-like test client completes `hello`;
3. USB and Wi-Fi receiver snapshots appear;
4. startSession creates the virtual display and streams;
5. stopSession removes session/display cleanly;
6. killing the control client triggers bounded engine cleanup;
7. real iPad USB stream passes;
8. real iPad Wi-Fi stream passes;
9. Screen Recording/Accessibility behavior is recorded;
10. inherited OpenDisplay update/version endpoints are not contacted.

No runtime PASS may be claimed from static/source evidence.

## Independent review

Because this task creates the first real proprietary-to-GPL process-control seam, require one independent read-only review of:

- engine/product responsibility split;
- local control protocol scope;
- lifecycle cleanup;
- upstream-preservation evidence;
- no GPL code movement into SideLinker-Source;
- no media proxying through proprietary SideLinker.

## Completion condition

Task 09 is complete only when:

- the review gate has passed;
- implementation is committed in the fork;
- source/build verification passes;
- required runtime baseline is recorded;
- documentation reflects actual behavior rather than intended behavior.
