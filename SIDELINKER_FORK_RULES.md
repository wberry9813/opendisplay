# SideLinker Direct — OpenDisplay Fork Rules

Status: **AUTHORITATIVE FOR THIS FORK**  
Fork: `wberry9813/opendisplay`  
Upstream baseline at Identity Bootstrap: `peetzweg/opendisplay main @ b9eec1f232fb5ea571c87e8392379a84f47b237f`  
License: **GPL-3.0** (unchanged)

## Purpose

This fork is the implementation workspace for SideLinker's Direct Display engine/receiver path.

The engineering strategy is **adapt latest OpenDisplay, do not rebuild it**. The mature virtual-display, capture, encode, transport, receiver, recovery and input implementation should remain as intact as practical.

The fork must stay clearly separable from the proprietary SideLinker product repository.

## Ownership boundary

### This GPL fork owns Direct runtime mechanics

- CGVirtualDisplay creation/lifecycle and Direct display policy;
- ScreenCaptureKit capture;
- VideoToolbox encode/decode;
- OpenDisplay sender/receiver wire protocol;
- Bonjour/usbmuxd media transport mechanics;
- receiver rendering;
- touch/scroll/pencil return input;
- Direct session-internal liveness/recovery;
- Direct-specific diagnostics.

### Proprietary SideLinker owns product policy

Do not move these into the GPL engine:

- StoreKit entitlement / Pro gating;
- SideLinker product UI/settings;
- Native Sidecar;
- DisplayCoordinator / neutral DisplayBackend;
- backend selection/fallback;
- CloudKit / Watch / BLE / LocalWeb product behavior;
- product-level preferred-device and retry policy;
- released product-visible status semantics.

The future SideLinker <-> Direct engine control surface must remain small and session-oriented. Media frames do not pass through proprietary SideLinker.

## Frozen fork identities

Task 08 establishes these identities once. Treat later changes as GUARDED because they invalidate permissions, provisioning, discovery or display-state continuity.

| Surface | SideLinker Direct identity |
| --- | --- |
| Mac sender release bundle | `com.dmer.sidelinker.direct.mac` |
| Mac sender Debug bundle | `com.dmer.sidelinker.direct.mac.debug` |
| Mac receiver release bundle | `com.dmer.sidelinker.direct.macreceiver` |
| Mac receiver Debug bundle | `com.dmer.sidelinker.direct.macreceiver.debug` |
| iOS/iPad receiver release bundle | `com.dmer.sidelinker.direct.receiver` |
| iOS/iPad receiver Debug bundle | `com.dmer.sidelinker.direct.receiver.debug` |
| Product name | `SideLinker Direct` |
| Mac receiver product name | `SideLinker Direct Receiver` |
| Bonjour service type | `_sidelinkerdirect._tcp` |
| Virtual-display vendor ID | `0x534C` ("SL") |
| Virtual-display product base | `0x5344` ("SD") |
| SideLinker App Store listing ID used for deep links | `6760007015` |

The App Store numeric ID is an update/review destination supplied by the operator. It does **not** assert that the GPL receiver target shares the existing proprietary SideLinker App Store bundle identifier or that the final mobile distribution architecture has been approved.

## Discovery compatibility decision

The wire protocol remains the OpenDisplay protocol (`pv = 3` at bootstrap).

The Bonjour service type intentionally changes from upstream `_opensidecar._tcp` to `_sidelinkerdirect._tcp`.

Result:

- SideLinker Direct peers discover each other;
- official OpenDisplay peers do not silently appear in SideLinker Direct discovery;
- USB framing/wire mechanics remain OpenDisplay-derived;
- this discovery namespace change alone does not authorize arbitrary wire incompatibility.

Do not change framing/control semantics merely to rebrand the fork.

## TCC / signing identity rule

macOS Screen Recording and Accessibility authorization is sensitive to bundle identity and signing requirement.

After the first stable runtime validation:

- do not casually change bundle IDs;
- do not alternate ad-hoc designated requirements;
- do not rebuild/re-sign the same tested binary between permission grant and validation;
- keep Debug and Release identities distinct.

## Distribution isolation

The fork must not consume upstream OpenDisplay release infrastructure as if it were ours.

Identity Bootstrap therefore disables:

- upstream Sparkle `SUFeedURL`;
- upstream Sparkle public key;
- automatic Sparkle checks;
- upstream `opendisplay.app/ios-version.json` remote gate;
- automatic GitHub release/TestFlight workflow execution;
- automatic GitHub Pages deployment.

Publishing remains opt-in behind repository variable:

`SIDELINKER_FORK_PUBLISH_ENABLED=true`

Do not enable that variable until SideLinker-owned signing keys, App Store/TestFlight target, Sparkle feed/key, web endpoint and GPL source/distribution obligations have been reviewed.

## Upstream sync discipline

The fork should remain cheap to update from `peetzweg/opendisplay`.

Rules:

1. Preserve upstream implementation/file names unless renaming is required for runtime identity.
2. Prefer additive SideLinker files/seams over broad rewrites.
3. Keep fork-specific identity/config changes concentrated and documented.
4. Do not cosmetically rename internal types such as `MacSender`, `StreamReceiver`, `OpenSidecarMacApp`, target/scheme names or directory names merely for branding.
5. When syncing upstream, inspect conflicts in identity/distribution files manually; never accept an upstream version that silently restores official bundle IDs, Bonjour type, update feeds or publishing.
6. Keep upstream GPL license and attribution intact.
7. Record the upstream commit used for every major integration milestone.

## First implementation seam after Identity Bootstrap

Do not start by rewriting media internals.

The first substantive extraction should be a headless/service-oriented engine controller that reuses the current:

- `MacSender`;
- `VirtualDisplay`;
- `StreamConfiguration`;
- `Usbmux`;
- `StreamReceiver`;
- existing wire protocol.

The controller should expose receiver snapshots and bounded session lifecycle/status while leaving SideLinker product policy outside.

Final IPC transport, packaging, signing/notarization and distribution are separate guarded decisions.

## Change review checklist

For each fork-specific change ask:

- Is this required for Direct runtime or SideLinker integration?
- Can the upstream implementation stay unchanged behind a new seam?
- Does it alter GPL/proprietary coupling?
- Does it alter bundle/signing/TCC identity?
- Does it alter Bonjour discovery or wire protocol?
- Does it alter virtual-display vendor/product identity?
- Does it alter update/distribution infrastructure?
- Does it make future upstream sync materially harder?

If a change crosses licensing/distribution or proprietary-linking boundaries, stop for an explicit architecture/license decision rather than guessing.


## Task 09 runtime architecture decision

The first SideLinker-facing engine seam is specified by:

- `SIDELINKER_ENGINE_ARCHITECTURE.md`
- `SIDELINKER_ENGINE_CONTROL_PROTOCOL.md`
- `SIDELINKER_TASKS/09-headless-engine-controller.md`

For Task 09, SideLinker <-> engine control uses a **local Unix domain socket** with a small versioned length-prefixed JSON protocol.

This does not change the OpenDisplay sender/receiver media transport: engine <-> receiver remains the existing USB(usbmuxd)/Wi-Fi(TCP) path.

Task 09 should reuse the existing SideLinker Direct Mac bundle/TCC identity in a headless launch mode instead of creating another identity.

Substantive implementation remains blocked until the existing independent architecture/license-boundary review gate passes.


## Connection ownership / anti-race rule

Discovery does not equal permission to connect.

- Native Sidecar and Direct may each observe their own discovery signals.
- Proprietary SideLinker / DisplayCoordinator owns product connection intent and must choose the active backend.
- Managed/headless Direct mode must never start a new session solely from USB attach, Bonjour discovery, remembered-device state or discovery refresh.
- A successful `startSession` grants one Direct product session.
- The engine may autonomously recover that already-authorized session.
- A successful `stopSession` revokes the grant; later discovery/reconnect activity must not resurrect it.
- Standalone fork mode may retain upstream auto-connect policy for development, but managed mode must remain passive until explicitly authorized.
