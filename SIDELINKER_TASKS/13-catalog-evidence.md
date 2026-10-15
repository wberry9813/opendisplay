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
