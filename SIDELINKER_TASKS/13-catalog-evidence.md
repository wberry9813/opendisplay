# Task13 — Product catalog evidence / helper permission action

Status: WRITER IMPLEMENTED / BUILD + HOSTLESS SYNTHETIC TESTS PASS / INDEPENDENT REVIEW AND MANUAL ACCEPTANCE PENDING.

Product contract/design live in SideLinker-Source Task13 and
`docs/connection-modes-logical-device-catalog.md`. GPL foundation is exact
`f121628168166bec744b69c4587f12d42697cf3d`; branch `sidelinker/task13-catalog-evidence`.
Sole writer: operator-assigned ESCALATED_WRITER / OpenCode `openai/gpt-6.1-sol`.
Risk/cadence GUARDED / IMMEDIATE; no independent review run by the writer.

## Narrow control/source changes

- Receiver snapshot adds optional `usbUDIDs: [String]`, the sorted union of the entry's existing
  usbmux UDID and already-learned install-ID mappings. Deduplication preserves that union alongside
  transports. No proprietary discovery implementation or policy is introduced here.
- Transport correlation requires equal known install identities. Missing identities stay unresolved;
  same display names no longer establish physical identity. The obsolete name arguments are removed
  from this internal helper and callers/tests migrate directly. No compatibility wrapper.
- Existing greeted, local control owner may send `requestAccessibility` with no payload. The engine
  invokes `AXIsProcessTrustedWithOptions` with the prompt option in its own process, only for this
  explicit command. Discovery/startup/preflight never invokes the prompt.
- `requestAccessibility` and `listReceivers` return current helper preflight facts through the existing
  subscribed `permissionState` event (`screenRecording`, `accessibility`). No second permission channel,
  no auto-request, no media through control IPC. Older engine snapshots lacking the new optional facts
  cannot support cross-source correlation; the product does not guess by name.

No media/receiver wire protocol, capture/encode, virtual-display identity, mature touch/scroll/Pencil
implementation, bundle/signing identity, or GPL/proprietary boundary changes. Other tracked fork sources
are byte-compared against the accepted foundation by the product Task13 harness.

## Writer evidence (not device/TCC evidence)

Artifacts: `/Volumes/SSD240/Dev/SideLinker-artifacts/task13-connection-modes/`.
Generated ignored project using `./generate.sh`; no probe sources/references added.

```sh
xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecarMac -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /Volumes/SSD240/Dev/SideLinker-artifacts/task13-connection-modes/EngineDerivedData \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecarMac -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /Volumes/SSD240/Dev/SideLinker-artifacts/task13-connection-modes/EngineDerivedData \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -only-testing:OpenSidecarMacTests/EngineControlTests \
  -only-testing:OpenSidecarMacTests/EngineControllerTests test
```

Engine build BUILD SUCCEEDED (`engine-build-final.log`); hostless test TEST SUCCEEDED, 15 tests in
2 suites (`engine-tests.log`). Existing Swift-concurrency/AppIntents warnings remain, not repaired here.
No app/helper launch or live SMAppService/BTM/TCC/settings/hardware actions. Hostless tests compile sources
directly, do not inject into a product app, and never invoke the new Accessibility prompt.
Product harness additionally compiles production snapshot union/identity methods and checks the
helper-owned request source boundary; it does not prove real TCC attribution or permission UX.

Independent review and real-device Manual Acceptance remain PENDING. No release approval.

## Reviewed identity repair — 2026-10-15

Operator-supplied independent verdict on `f8b8a3a4bfefeac973d6444bd0a1226f457b4b95`:
**CHANGES REQUIRED**, same-name managed migration could manufacture a USB/install mapping.
This repair requires focused independent re-review; no review PASS or Manual Acceptance is claimed.

- Managed USB/Wi-Fi association and Wi-Fi failover no longer use display-name fallback. Managed
  upgrade additionally verifies the existing USB/install association against the session peer before
  changing transport. Choosing a transport never writes identity evidence, in either mode.
- Only a hello on the live USB route records USB/install evidence. A Wi-Fi hello cannot rewrite the
  original USB target's identity. The earlier unreleased `installIDByUDID` cache could contain guessed
  associations, so it is not imported as verified data; `verifiedUSBInstallIDByUDID` is rebuilt from
  actual USB hellos. No live settings reset/migration command was performed. An injected defaults
  suite isolates hostless persistence tests; production defaults remain standard.
- The product focused harness compiles the exact association/upgrade/recovery/snapshot method bodies
  with value-only Wi-Fi discovery and sender fixtures. Against the reviewed code the active Wi-Fi A /
  distinct same-name USB B case failed three checks: migration, mapping contamination and false strong
  snapshot evidence. It now passes, along with independently verified same-device migration. This is
  hostless synthetic policy evidence, not real network migration. NWBrowser.Result has no public
  initializer, so no real browser or private initializer is used to manufacture test discovery.
- A new actual-controller hostless test models A's Wi-Fi continuation after a verified USB hello,
  rejects namesake B and the old untrusted cache, verifies Wi-Fi cannot rewrite USB evidence, and
  retains verified A migration. The injected sender is stopped before transport policy changes,
  preventing fake USB dialing or display creation.

Same engine build/test commands above, with DerivedData/log root changed to
`/Volumes/SSD240/Dev/SideLinker-artifacts/task13-connection-modes/review-repair/`.
Engine arm64 Debug **BUILD SUCCEEDED** (`engine-build.log`); hostless **TEST SUCCEEDED**, **16 tests
in two suites** (`engine-tests.log`). Product full focused suite **PASS** (`focused-repair-final.log`),
including the exact-method managed Wi-Fi migration regression. `git diff --check` PASS.
Media/input, receiver wire protocol, helper identity, signing/package layout and licensing boundary
remain unchanged. No app/helper launch, live service/TCC/settings or hardware actions. Re-review and
Manual Acceptance remain PENDING.

## Task13 identity fingerprint capture companion — 2026-10-15

From product documentation head `33ee6933a1652bcac8b302ea51740670460205da`, same sole writer,
GUARDED / IMMEDIATE. Operator reports Better/Direct both connect; the unresolved issue is Native /
Direct correlation, not reachability. No new BLE/HTTP/wake work is activated.

Development-only OSLog subsystem `com.dmer.SideLinker.DirectEngine`, category `identity`, prefix
`SLIdentity v1`: USB observations, Bonjour TXT install evidence, verified mappings/USB hello, pair
decisions, snapshot rows and snapshot grouping. All hardware/install/name/route values are stable
SHA-256-prefix fingerprints. Casefold fingerprints are diagnostic comparison aids, never policy.
Identical facts are coalesced in bounded in-memory diagnostic storage, not persisted product state.
Normal usbmux/controller logs that contained raw route/UDID strings now use fingerprints too.

On the existing subscribe operation, DEBUG clears only diagnostic coalescing and logs the current
discovery inventory before the existing publishSnapshots. This ensures a fresh operator capture gets
facts from an already-running helper; no discovery call, wire field, policy, session or permission action
is added. Discovery/migration/media/input behavior remains unchanged. No GPL source moved into the app.

Verification root: `/Volumes/SSD240/Dev/SideLinker-artifacts/task13-connection-modes/identity-ui/`.
Ignored project regenerated via generate.sh for the new file. Same arm64 Debug engine build and
selected hostless commands as above, using `identity-ui/EngineDerivedData`: BUILD SUCCEEDED;
TEST SUCCEEDED, **17 tests in two suites**, including stable/private diagnostic fingerprint fixtures.
Product full focused suite and exact-method migration fixtures PASS. git diff --check PASS.
No helper/app launch, live service/BTM/TCC/settings/hardware actions by writer. Runtime identity bridge
still requires operator fingerprints; no name/shape heuristic, review PASS, waiver or acceptance claimed.
