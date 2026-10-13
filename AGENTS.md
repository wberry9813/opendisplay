# SideLinker Direct fork development rules

Read `SIDELINKER_FORK_RULES.md` before substantive work. This fork remains GPL-3.0 and preserves the upstream OpenDisplay license and attribution.

## Identity freeze

These identities are frozen after Task 08 Identity Bootstrap:

- macOS sender release: `com.dmer.sidelinker.direct.mac`
- macOS sender Debug: `com.dmer.sidelinker.direct.mac.debug`
- macOS receiver release: `com.dmer.sidelinker.direct.macreceiver`
- macOS receiver Debug: `com.dmer.sidelinker.direct.macreceiver.debug`
- iOS/iPad receiver release: `com.dmer.sidelinker.direct.receiver`
- iOS/iPad receiver Debug: `com.dmer.sidelinker.direct.receiver.debug`
- Bonjour service type: `_sidelinkerdirect._tcp`
- virtual display vendor/product base: `0x534C` ("SL") / `0x5344` ("SD")

Do not casually change bundle identifiers, signing requirements, Bonjour type, or virtual-display vendor/product identity. macOS TCC associates Screen Recording and Accessibility grants with bundle identifier + signing requirement.

## Local macOS development

- Keep Debug builds separate from release bundle IDs.
- Build the sender into `build/Build/Products/Debug/SideLinker Direct Dev.app` and launch with `./run.sh`.
- `run.sh` gives ad-hoc Debug builds a stable designated requirement based on `com.dmer.sidelinker.direct.mac.debug`.
- Do not rebuild or re-sign a Debug binary after granting Screen Recording during the same validation cycle.
- If Screen Recording is stale: quit the app, run `tccutil reset ScreenCapture com.dmer.sidelinker.direct.mac.debug`, launch the unchanged app, grant permission, and restart once.
- Existing Intel receiver test host may still be used as `ssh imac`; deploy the Debug receiver to `~/Applications/SideLinker Direct Receiver Dev.app`.

## Fork architecture rules

- Adapt latest OpenDisplay; do not reimplement its virtual-display/capture/encode/transport/receiver pipeline without explicit operator approval.
- Keep GPL media/wire implementation in this fork; do not copy it into the proprietary SideLinker repository.
- SideLinker product policy (StoreKit, UI, Native Sidecar, backend selection/fallback, CloudKit, BLE, LocalWeb) stays outside.
- Preserve the existing OpenDisplay sender/receiver wire protocol unless a task explicitly authorizes a protocol change.
- SideLinker <-> engine control must stay narrow and session-oriented; proprietary SideLinker must not proxy media frames.
- Prefer additive seams/new files over broad rewrites so upstream remains mergeable.
- Internal upstream type/file/scheme names do not need cosmetic renaming.
- Do not remove upstream copyright, GPL license text, or attribution.

## Distribution safety

Inherited OpenDisplay Sparkle feeds/public keys, Pages publishing, remote iOS version gate, and automatic release workflow are disabled in this fork.

Do not re-enable publishing until SideLinker-owned signing/update infrastructure and GPL distribution obligations are explicitly reviewed.
