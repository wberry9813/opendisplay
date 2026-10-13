# Task 08 — SideLinker Direct Fork Identity Bootstrap

Status: **IMPLEMENTED / STATIC SELF-CHECK PASS / INDEPENDENT REVIEW PENDING / RUNTIME NOT YET CLAIMED**  
Risk: **GUARDED**  
Branch: `sidelinker/task08-identity-bootstrap`  
Starting upstream/fork checkpoint: `b9eec1f232fb5ea571c87e8392379a84f47b237f`

## Operator decisions

- latest OpenDisplay remains the implementation baseline;
- this fork is the GPL Direct Display implementation workspace;
- all upstream app targets receive SideLinker-owned runtime identities;
- SideLinker App Store numeric ID for update/review links: `6760007015`;
- identity changes happen before first serious TCC/device runtime and are then frozen;
- internal upstream types/files are not cosmetically renamed.

## Goal

Create a clean SideLinker Direct identity boundary before engine extraction or real runtime validation.

This task changes identity/configuration/distribution safety only. It does not rewrite the media pipeline.

## Implemented identity map

- Mac sender: `com.dmer.sidelinker.direct.mac`
- Mac sender Debug: `com.dmer.sidelinker.direct.mac.debug`
- Mac receiver: `com.dmer.sidelinker.direct.macreceiver`
- Mac receiver Debug: `com.dmer.sidelinker.direct.macreceiver.debug`
- iOS/iPad receiver: `com.dmer.sidelinker.direct.receiver`
- iOS/iPad receiver Debug: `com.dmer.sidelinker.direct.receiver.debug`
- product naming: `SideLinker Direct` / `SideLinker Direct Receiver`
- Bonjour: `_sldirect._tcp`
- virtual display vendor/product base: `0x534C` / `0x5344`
- App Store deep-link ID: `6760007015`

## Distribution safety changes

Inherited OpenDisplay distribution identity is disabled rather than redirected to an invented SideLinker endpoint:

- Sparkle upstream feed removed;
- Sparkle upstream public key removed;
- automatic Sparkle checks disabled;
- remote `opendisplay.app` iOS VersionGate fetch disabled;
- dormant local version-policy artifact points at SideLinker App Store ID;
- release workflow is manual and additionally requires `SIDELINKER_FORK_PUBLISH_ENABLED=true`;
- Pages workflow is manual and requires the same opt-in variable;
- iOS UI links point to the SideLinker App Store and this fork/release area rather than upstream product/support endpoints.

The App Store ID is a link destination only. This task does not claim the GPL receiver can be uploaded as the existing proprietary SideLinker App Store bundle.

## Discovery behavior

The fork intentionally stops advertising/browsing upstream `_opensidecar._tcp` and uses `_sldirect._tcp`.

Task09's operator-approved pre-runtime standards correction supersedes the earlier 16-character bootstrap service value before the first serious signed/device/TCC baseline. The current service name is eight ASCII characters excluding the leading underscore, within the 15-character limit in RFC6335 §5.1 / RFC6763 §7.2 and Apple's DNS-SD APIs. All other Task08 identities and OpenDisplay media v3 remain unchanged; no historical-service alias is retained.

The underlying OpenDisplay protocol remains version 3. No framing/media/control semantic change is made.

## Virtual display identity

The upstream synthetic display namespace `0x5043 / 0x4F53` is changed to `0x534C / 0x5344` ("SL" / "SD"). Sender code and quality tools are kept consistent with the new values.

## TCC identity

`run.sh` uses the SideLinker Direct Debug app path and stable designated requirement `com.dmer.sidelinker.direct.mac.debug`.

The matching `tccutil reset ScreenCapture` command is documented in `AGENTS.md`.

## Explicitly unchanged

- GPL-3.0 license and upstream attribution/history;
- target/scheme/internal Swift type names;
- ScreenCaptureKit capture implementation;
- VideoToolbox encode/decode implementation;
- usbmuxd implementation;
- transport framing and protocol version;
- receiver rendering/input/recovery mechanics;
- proprietary SideLinker repository.

## Verification scope

This GitHub checkpoint provides static source/config evidence only.

Required before runtime PASS:

- generate the Xcode project from updated `project.yml`;
- unsigned compile/test;
- inspect signed Debug sender identity;
- grant Screen Recording against the new Debug bundle;
- grant Accessibility when input is tested;
- confirm virtual display reports the new vendor/product IDs;
- install/sign the iPad receiver with the new Debug identity;
- confirm Wi-Fi discovery uses only `_sldirect._tcp`;
- confirm USB end-to-end streaming;
- confirm no inherited OpenDisplay update/version endpoints are contacted.

## Next step

After static review, extract a headless Direct engine controller while preserving `MacSender`, `VirtualDisplay`, `Usbmux`, `StreamReceiver` and the existing media protocol.

Final product IPC, distribution packaging, signing/notarization and GPL source-offer mechanics remain later guarded decisions.


## Static self-check repair

After the first GitHub checkpoint, source inspection caught and repaired two configuration issues before runtime work:

- removed an accidentally duplicated `configs:` block from the Mac sender and placed the iOS Debug bundle override under the iOS target;
- added the documented `SIDELINKER_FORK_PUBLISH_ENABLED == true` guard to the manual Pages deploy job.

No runtime/build PASS is inferred from this static repair.
