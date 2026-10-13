# Task 09 — Headless Direct Engine Controller

Status: **COMPLETE / WRITER VERIFIED / INDEPENDENT REVIEW PASS_WITH_NONBLOCKING_FINDINGS / OPERATOR REAL-DEVICE RUNTIME ACCEPTED**
Risk: **GUARDED / IMMEDIATE**  
Branch: `sidelinker/task09-headless-engine-controller`  
Starting checkpoint: `595ce69a2feda8eafb7ba2c310fcca2c366baa3d`  
Operator-authorized implementation head: `7f67f64e63cc5098dac114325e75986e2ca89b00` (accepted design/docs above the identity baseline)
Final reviewed/runtime checkpoint: `f121628168166bec744b69c4587f12d42697cf3d`
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

## Design acceptance

The operator has accepted the current architecture for implementation.

No separate independent review is required for this design/documentation checkpoint. Task 09 source implementation may begin from the accepted Identity Bootstrap baseline.

Independent review is retained for the **implemented code checkpoint**, not as a precondition to start coding.

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

## Implementation sequence

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

## Implementation checkpoint review

After implementation and writer verification, require one independent read-only review of the resulting code checkpoint.

Review focus:

- engine/product responsibility split;
- local control protocol scope;
- discovery-vs-connection ownership behavior;
- lifecycle cleanup and stopSession non-resurrection;
- upstream-preservation evidence;
- no GPL code movement into SideLinker-Source;
- no media proxying through proprietary SideLinker.

## Completion condition

Task 09 is complete only when:

- implementation is committed in the fork;
- source/build verification passes;
- required runtime baseline is recorded;
- documentation reflects actual behavior rather than intended behavior.

## Writer implementation checkpoint — 2026-10-13

Writer: sole `ESCALATED_WRITER`, `openai/gpt-6.1-sol`, explicitly authorized for this architecture-sensitive seam. Scope: this GPL fork only; no proprietary repository files modified. No other implementation writer or reviewer was dispatched. Current quota remains unknown; the parent's partial Oct12 snapshot was not treated as current quota. The proprietary quota-update script was deliberately not invoked because it writes the prohibited repository.

### Implemented behavior

- `Mac/Engine/DirectEngineController.swift` owns the extracted upstream Bonjour/usbmux discovery, identity correlation, session registry, sender construction and orchestration. Standalone presentation policy is a small `SenderController` adaptor in `Mac/OpenSidecarMacApp.swift`; the existing views/permission UI are relocated to `Mac/StandaloneSenderUI.swift` without executable-view changes (comment/whitespace-normalized comparison).
- Managed discovery remains active but passive without an explicit grant. One idempotent managed session is authorized by `startSession`; a different receiver/preference returns `session.busy`. `stopSession` revokes authority before sender teardown, cancels owned startup tasks and clears permitted targets. Registry identity checks reject delayed sender callbacks; generation checks make delayed replacement/recovery work inert after revocation, including after a new grant.
- The existing sender retains its intra-session reconnect/capture recovery. The controller can replace an ended/sleeping pipeline under the same managed grant, matching the original receiver identity or a learned install identity. `auto` permits USB preference/failover; `usb` forbids Wi-Fi failover; `wifi` forbids USB upgrade and constrains the sender's TCP/UDP connection parameters to Wi-Fi and disables internal cable-upgrade probing. These transport paths still need real-device verification.
- Receiver snapshots combine already-correlated rows by install identity, expose available transports, known device/protocol compatibility and panel/codec metadata after hello, and do not expose transient usbmux `DeviceID` as product identity. Strong conflicting install IDs do not merge solely by name; upstream name correlation remains a fallback when stronger evidence is absent. Older receivers without install evidence retain transport-scoped identity limitations; no new identity migration machinery was added.
- `--engine` uses the existing sender target/bundle identity, suppresses menu-bar/control-window presentation and runs the same extracted controller plus `LocalControlServer`. Standalone retains independent multiple sessions and its existing development auto-connect policy. No new bundle, entitlement, signing or release infrastructure was introduced.
- Local control is AF_UNIX at `~/Library/Application Support/SideLinker/Direct/engine.sock`, not TCP. Owner-checked directories, owner-private `0700` containing directory / `0600` socket, `O_NOFOLLOW` lock checks, exclusive `flock`, safe owned stale-socket replacement, inode-checked cleanup and same-user `getpeereid` checks protect ownership. A second controlling client is rejected; no takeover. Handshake deadline is 5 seconds; pending output is bounded to 1 MiB and a 10-second stalled-write deadline. Owner loss/shutdown revokes the grant immediately, drains responses for at most 0.2 seconds, cleans descriptors/socket and requests exit, with a 1-second process-exit backstop. These are implementation bounds, not active-display runtime timing claims.
- Protocol v1 implements 4-byte BE framing, UTF-8 object validation, 262144-byte maximum, hello-first, all six required methods and all five required event families. Unsupported methods return `protocol.unknownMethod`; competing owners return `control.ownerExists`. Subscription is subscribe-to-all. Permission preflight uses `granted` or `unknown` because false preflight does not distinguish denied from not-yet-determined; no managed permission-request UI is invoked. Media never traverses this IPC.

### Frozen-media evidence

`tools/task09-source-checks.py` verifies 48 frozen tracked media/receiver/identity/distribution/accepted-contract paths byte-identical to the operator-authorized head. All production target configuration in `project.yml` is unchanged; only the hostless Mac test target's source inputs/dependency were widened to compile the real engine orchestration. Generated Info.plists are untracked, so identity preservation is checked against their authoritative project configuration, not falsely against missing Git objects.

`Mac/MacSender.swift` has exactly seven allowlisted integration substitutions: immutable `wifiOnly` storage, defaulted initializer option/assignment, a cancellation/terminal-stop guard at startup, cable-probe guard, and Wi-Fi interface constraints on TCP/UDP parameters. No virtual-display, capture, codec, framing, rotation, keyframe or receiver algorithm was rewritten. The delayed-start guard is tested by stopping a sender and attempting `start()` without dialing. All other frozen areas, `Shared/`, iOS and workflows remain unchanged.

### Actual verification and artifacts

Artifact root: `/Volumes/SSD240/Dev/SideLinker-artifacts/task09-writer/`.

1. **Project generation executed:** `./generate.sh` — succeeded. XcodeGen picked up the additive engine/UI/test files. No generated project or plist is committed.
2. **Executed unsigned arm64 Debug tests:**

   ```sh
   xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecarMac \
     -configuration Debug -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath /Volumes/SSD240/Dev/SideLinker-artifacts/task09-writer/DerivedData \
     -resultBundlePath /Volumes/SSD240/Dev/SideLinker-artifacts/task09-writer/Tests-checkpoint.xcresult \
     CODE_SIGNING_ALLOWED=NO test
   ```

   `tests-checkpoint.log`: **TEST SUCCEEDED**. Existing **114 XCTest tests**, zero failures; **19 Swift Testing tests in three suites**, including parameterized framing/parser cases, passed. Synthetic controller tests inject a no-op sender-start operation and permission predicate: no receiver dial, display creation, capture or hardware streaming is established by them. They exercise passive USB inventory and empty Bonjour refresh paths, explicit/idempotent grants, busy/preference rejection, denied permission, unrelated-target rejection, stale sleep/hello/disconnect callbacks, same-grant sleep/disconnect replacement, delayed recovery revocation, terminal sender start rejection and standalone multi-session cardinality. Pure snapshot tests cover install-ID merge vs conflicting/name-only evidence. Nonempty real Bonjour/USB correlation and real transport migration remain runtime pending.

   Real local Unix socket tests also execute hello-first / unknown-method / second-owner behavior, private modes, duplicate engine lock rejection, stale owned-socket recovery, symlink preservation and socket cleanup. Same-user peer checks are exercised by normal client acceptance; a different-user process was not launched.
3. **Executed sender/headless-mode build:**

   ```sh
   xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecarMac \
     -configuration Debug -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath /Volumes/SSD240/Dev/SideLinker-artifacts/task09-writer/DerivedData \
     CODE_SIGNING_ALLOWED=NO build
   ```

   `build-checkpoint.log`: **BUILD SUCCEEDED**. Standalone UI and headless runtime branch compile in this same target; no separate identity/target is needed. App artifact: `DerivedData/Build/Products/Debug/SideLinker Direct Dev.app`. Existing upstream Swift-6 concurrency warnings in the Swift-5.9 media/usbmux code remain; no blanket suppression or concurrency migration was attempted.
4. **Executed source/boundary checks:** `python3 tools/task09-source-checks.py` — `source-checks-repaired.log` records frozen-byte comparisons, exact sender allowlist, unchanged production identity/distribution configuration, relocated-view equivalence, UI-independent controller/headless/AF_UNIX wiring and `git diff --check` PASS. Final documentation-inclusive check: `source-checks-checkpoint.log`. These are source checks, not device/runtime proofs.
5. **Executed real Mac, unsigned control-only smoke:**

   ```sh
   python3 tools/task09-control-smoke.py "/Volumes/SSD240/Dev/SideLinker-artifacts/task09-writer/DerivedData/Build/Products/Debug/SideLinker Direct Dev.app/Contents/MacOS/SideLinker Direct Dev"
   ```

   `control-smoke-checkpoint.log` records successful `--engine` launch, fragmented request delivery, hello-first/hello, subscribe/list snapshots, unsupported-method error, second-owner rejection, idempotent stop/shutdown, `0700`/`0600` modes and socket cleanup. A second launch's owner EOF exited/cleaned the socket in **0.452 seconds** with **no active display session**. Final rerun `control-smoke-events.log` additionally asserts all five event families and that observed session snapshots stay idle without a grant; owner EOF cleanup took **0.476 seconds**. The smoke never calls `startSession`, requests TCC grants or interacts with permission dialogs. It does not prove populated receiver snapshots, signed launch, no-window visual acceptance, active display cleanup, streaming, input or hardware behavior.

Unix socket unit fixtures use short `/tmp/task09-<random>/Direct/engine.sock` paths and remove them at teardown: this is a technical exception to SSD artifact preference because Darwin `sockaddr_un.sun_path` is 104 bytes and XCTest temporary-directory paths can exceed that limit. Build/test reports remain on SSD.

### Failures retained and repaired

- The initial build hit the 200-second tool timeout during its first dependency/build invocation (`build.log`, BUILD INTERRUPTED); the longer retry built successfully (`build-retry.log`). No foundation capability was downgraded from a task timeout.
- Expanded server tests failed on existing-directory handling (`tests-final.log` / `tests-verified.log`); the first control smoke completed shutdown checks but failed relaunch for the same defect (`control-smoke.log`). Startup now validates/reuses the existing private directory before lock/stale-socket checks. All affected tests subsequently passed (`Tests-repaired.xcresult` and final `Tests-checkpoint.xcresult`).
- A subsequent unsigned app smoke hit its 15-second socket-startup deadline without a new engine startup log (`control-smoke-repaired.log`); root cause was not established. The checkpoint smoke preserves stderr/stdout, allows a bounded 30-second startup, and both launches completed. This timeout is retained as an uncharacterized unsigned-startup observation, not a signed compatibility claim.
- The first source-check harness incorrectly assumed generated Info.plists were tracked Git files (`source-checks.log`). The corrected harness checks unchanged production target configuration and passed; this was a verification-fixture error, not an identity change.

### Gate state / next step

- Writer source/build verification: **PASS at the evidence levels above**.
- Independent implementation review: **PENDING**, GUARDED / IMMEDIATE; no independent review performed by this writer. Do not merge/cross the review boundary on this report alone.
- Signed Debug/TCC, populated USB/Wi-Fi snapshots, real `startSession`/virtual display/stream, real stop/display teardown, active-session owner-loss cleanup, iPad USB/Wi-Fi media, Accessibility/input and network/update-endpoint runtime matrix: **PENDING**. Disabled distribution endpoints are source-preserved, not packet-capture-verified.
- Operator Manual Acceptance: **PENDING**. Task09 is not complete/sealed/release-approved.
- Next: one independent read-only checkpoint review, then stable signed Debug and real-device runtime/operator acceptance. No proprietary backend implementation is included.

## Pre-runtime correction — Bonjour service name (2026-10-13)

Operator-authorized pre-runtime standards correction applied before the first serious signed/device/TCC Bonjour runtime baseline. This changes only the discovery-token value; no media/framing/control semantics and no other Task 08 identity changes.

### Defect

The Task 08 bootstrap Bonjour type carried a 16-character DNS-SD service name. RFC 6335 §5.1 and RFC 6763 §7.2 — and Apple's DNS-SD/`Network.framework` APIs — limit a service name to 15 characters, so the advertised/browsed type was invalid. It never reached a signed/device baseline. No bytes on the media wire are affected. The superseded literal survives only as the immutable `7f67f64` baseline that `tools/task09-source-checks.py` reads programmatically; it is deliberately absent from the working tree.

### Correction

The bootstrap type becomes `_sldirect._tcp` (service name `sldirect`, 8 ASCII characters), applied consistently to every production and evidence surface:

| Surface | Files |
| --- | --- |
| Sender browser | `Mac/Engine/DirectEngineController.swift` |
| Receiver listener | `Shared/StreamReceiver.swift` |
| Project config (Mac / MacReceiver / iOS) | `project.yml` |
| Tracked receiver plist | `MacReceiver/Info.plist` |
| Generated plists (Mac / iOS) | regenerated from `project.yml` via `./generate.sh` |
| Protocol/identity docs | `PROTOCOL.md`, `SIDELINKER_FORK_RULES.md`, `SIDELINKER_ENGINE_ARCHITECTURE.md`, `AGENTS.md`, `SIDELINKER_TASKS/08-identity-bootstrap.md` |
| Source checks | `tools/task09-source-checks.py` (derives the historical token from the immutable baseline; adds a standards-limit check, browser/listener/three-plist binding check and zero-stale-token scan over ignored/generated files, Git history excluded) |
| New test | `MacTests/BonjourIdentityTests.swift` |

Preserved unchanged: OpenDisplay protocol/media version 3, and every other Task 08 identity (bundle IDs, virtual-display vendor/product `0x534C`/`0x5344`, App Store deep-link ID). No historical-service alias is retained; the working tree contains zero superseded bootstrap tokens outside Git history. `SIDELINKER_TASKS/08-identity-bootstrap.md` records the supersession in prose only, without leaving the stale literal in the tree.

### Evidence (this correction)

Artifact root: `/Users/dmer/SideLinker-artifacts/task09-bonjour-fix/`. Build/DerivedData was placed on the internal Data volume because the preferred SSD artifact volume was full (32 Mi free); logs and the result bundle are copied to the durable artifact root.

1. `./generate.sh` — succeeded; regenerated `Mac/Info.plist`, `MacReceiver/Info.plist` and `iOS/Info.plist`, all advertising `_sldirect._tcp`.
2. `xcodebuild … CODE_SIGNING_ALLOWED=NO test` — `tests-bonjour-fix.log`: **TEST SUCCEEDED**; 114 XCTest tests, zero failures; 20 Swift Testing tests in 4 suites (including the new `BonjourIdentityTests`).
3. Sender unsigned arm64 Debug build — `build-bonjour-fix.log`: **BUILD SUCCEEDED**; `SideLinker Direct Dev.app` embeds `_sldirect._tcp` and `com.dmer.sidelinker.direct.mac.debug`.
4. Mac receiver unsigned arm64 Debug build — `build-receiver.log`: **BUILD SUCCEEDED**; `SideLinker Direct Receiver Dev.app` embeds `_sldirect._tcp` and `com.dmer.sidelinker.direct.macreceiver.debug`.
5. iOS unsigned build (`generic/platform=iOS Simulator`) — `build-ios.log`: **BUILD SUCCEEDED**; `OpenSidecariOS.app` embeds `_sldirect._tcp` and `com.dmer.sidelinker.direct.receiver.debug`.
6. `python3 tools/task09-source-checks.py` — `source-checks-bonjour-fix.log`: all PASS, including the ≤15-character RFC 6335/6763 name check, the three generated `NSBonjourServices` bindings, the zero-stale-token scan, and terminating `git diff --check` PASS.

These remain source/build checks. Signed/TCC launch, populated USB/Wi-Fi snapshots, real `startSession`/stream/teardown, iPad USB/Wi-Fi media, Accessibility/input and the endpoint runtime matrix remain **PENDING**.


## Independent implementation review — 2026-10-13

Review checkpoint: `f121628168166bec744b69c4587f12d42697cf3d` against accepted implementation baseline `7f67f64e63cc5098dac114325e75986e2ca89b00`.

Reviewer route: agy `gemini-3.8-flash-high`, independent from the implementation writer. Verdict: **PASS_WITH_NONBLOCKING_FINDINGS**.

The reviewer found no blocking defect in the managed discovery/session authority split, stop/recovery generation guards, standalone compatibility, AF_UNIX control ownership/security/framing, headless launch identity, narrow `MacSender` integration, GPL/proprietary boundary, lifecycle/concurrency handling, or the corrected `_sldirect._tcp` Bonjour identity. Reviewer-reported reproduction included Task 09 source checks, the Mac test suite (114 XCTest + 20 Swift Testing tests, zero failures), and the control-only headless smoke.

Two LOW/nonblocking residual findings were accepted without code churn:

1. managed/headless display-size helpers still touch shared `UserDefaults.standard`; no observed runtime defect and no product-policy leakage was demonstrated;
2. `LocalControlServer.acceptClients()` bounds one dispatch pass to 16 accepts rather than draining until `EAGAIN`; the product contract has one legitimate control owner and the bound is acceptable as an anti-starvation limit for this checkpoint.

No second independent reviewer is required for Task 09.

## Operator real-device runtime acceptance — 2026-10-13

The operator executed the Debug sender/receiver on real Apple hardware and exercised both standalone and managed/headless paths. This is real-device runtime evidence, not static inference.

Accepted runtime results:

- standalone Direct receiver streaming over **USB: PASS**;
- standalone Direct receiver streaming over **Wi-Fi: PASS**;
- `--engine` launches headless and creates the private control socket without automatically creating a display from discovery alone: **PASS**;
- control directory/socket modes observed as `0700` / `0600`: **PASS**;
- USB receiver discovery in managed mode: **PASS**;
- Wi-Fi receiver discovery in managed mode: **PASS**;
- pre-hello USB identity upgraded from a transport-scoped `device:<udid>` identity to the receiver install identity after hello, and USB + Wi-Fi correlated into one receiver exposing both transports: **PASS**;
- requesting an unavailable transport returned `transport.unavailable`: **PASS**;
- explicit managed `startSession` over **USB** created the virtual display, completed receiver hello, selected HEVC, started ScreenCaptureKit capture and rendered on the receiver: **PASS**;
- explicit managed `startSession` over **Wi-Fi** did the same over the Wi-Fi path: **PASS**;
- `auto` selected USB while USB was available: **PASS**;
- while one managed grant remained active, physical USB detach migrated the same authorized session to Wi-Fi without a new product-level `startSession`: **PASS**;
- reattaching USB migrated that same authorized session back to USB: **PASS**;
- explicit `stopSession` tore the display/session down and subsequent USB/Wi-Fi discovery changes did **not** resurrect it until a new `startSession`: **PASS**;
- terminating the controlling client caused owner-EOF cleanup: the display/session stopped, the engine process exited, and `engine.sock` was removed: **PASS**;
- Screen Recording permission was functional in the real stream path: **PASS**;
- Accessibility/input return was exercised on real iPad hardware with finger touch and Apple Pencil input reaching macOS: **PASS**.

The operator manually stopped ScreenCaptureKit during some exploratory runs; the resulting `SCStreamErrorDomain` user/system-stopped errors were therefore expected test actions, not spontaneous engine failures.

### Runtime evidence limits retained

- two-finger scrolling was not separately required as a Task 09 blocking acceptance item after real finger/Pencil injection proved the Accessibility/input-return path;
- no separate packet-capture claim is made for update/version endpoints. Inherited OpenDisplay distribution endpoints remain disabled by the accepted source/config boundary; final distribution/update/network verification belongs to later packaging/release work;
- final installer/helper placement and whether the engine app bundle is embedded or installed in Application Support remain explicitly deferred. Task 09 proves the separate-process engine boundary, not final packaging UX.

## Final gate state

- Writer implementation/source/build verification: **PASS** at the recorded evidence levels.
- Independent implementation review: **PASS_WITH_NONBLOCKING_FINDINGS**.
- Operator real-device runtime / Manual Acceptance for the Task 09 engine scope: **PASS**.
- Final implementation/runtime checkpoint: `f121628168166bec744b69c4587f12d42697cf3d`.
- Task 09 is **COMPLETE**. The next architecture phase is proprietary SideLinker `DirectDisplayBackend` integration and Native/Direct arbitration; no proprietary Direct backend implementation is included in this fork task.
