# Managed input post-event access probe

Base: accepted/reviewed/runtime checkpoint `f121628168166bec744b69c4587f12d42697cf3d`.
Branch: `probe/managed-input-postevent-access-retry`.
Operator explicitly requested a sole writer and a dedicated diagnostic branch.

## Instrumentation

Only `--engine` enables diagnostics. A lock-protected budget belongs to each
MacSender (one authorized session), survives injector rebuilds, and emits:

- once at input injector readiness: PID, AXIsProcessTrusted and non-prompting
  CGPreflightPostEventAccess (availability guarded);
- once per touch/scroll/pencil message type received by MacSender, before field
  validation/dispatch, including whether the injector exists;
- immediately before and after the first actual CGEvent post, including event
  type before, permissions both times, and explicit unobservable delivery status.

All four post sites (mouse, scroll, tablet proximity, tablet point) share the same
budget. No coordinates or per-event traces. No request API or prompt added.
Standalone follows the same post tap and existing behavior without probe logs.

## AX wait inspection

MacSender.setupExtend installs InputInjector before startCapture. After that
returns, start() polls AX trust for status/log reporting. The independent
sender.video control callback already dispatches touch/scroll/pencil straight
to InputInjector, whose handlers have no AX permission guard. The polling wait
does not block that input path. It is preserved, without a managed bypass.

CGEvent.post returns Void: a returned call does not prove OS delivery. The probe
is intended to distinguish arrival/injector readiness/post attempts from denied
post-event preflight. Operator runtime, not source inspection, determines whether
the helper's denied permission explains the failure.

## Operator condition and evidence limits

Keep SideLinker Mac Accessibility ON and SideLinkerDirectEngine Accessibility OFF.
Do not grant helper access for this test. Screen Recording/operator runtime facts
are supplied by the operator; this probe does not re-test or modify them.

No protocol/media/identity/signing/product-source changes. Existing Task10 build
machinery embeds and Development-signs the separately built fork artifact.
Builds use REGISTER_APP=NO to avoid LaunchServices registration. No GUI, real
engine launch, service registration, TCC/BTM/settings changes, socket deletion,
or hardware interaction is part of writer verification. Runtime acceptance is
PENDING until the operator executes the test.

The Task09 source checker reverses only marked diagnostic additions and exact
injector/post-site substitutions before its existing frozen-boundary comparisons;
it is static preservation evidence, not runtime authorization evidence.
