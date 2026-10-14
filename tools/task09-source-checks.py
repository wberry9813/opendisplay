#!/usr/bin/env python3
"""Task09 source/frozen-boundary evidence, NOT runtime/media verification."""
import re
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = "7f67f64e63cc5098dac114325e75986e2ca89b00"


def original(path):
    return subprocess.check_output(["git", "show", f"{BASE}:{path}"], cwd=ROOT)


# Operator-approved pre-runtime identity correction only. Read the historical
# value from the immutable baseline instead of leaving its literal in the tree.
SERVICE = "_sldirect._tcp"
prior_project = original("project.yml").decode()
bootstrap_service = re.findall(r'NSBonjourServices: \["([^"\s]+)"\]', prior_project)
assert len(bootstrap_service) == 3 and len(set(bootstrap_service)) == 1
bootstrap_service = bootstrap_service[0]
assert len(bootstrap_service.split(".")[0][1:]) == 16
identity_substitutions = {
    "Shared/StreamReceiver.swift": 1,
    "SIDELINKER_FORK_RULES.md": 2,
    "SIDELINKER_ENGINE_ARCHITECTURE.md": 2,
    "project.yml": 3,
}


def approved_identity(path, data):
    if path in identity_substitutions:
        old = bootstrap_service.encode()
        assert data.count(old) == identity_substitutions[path], f"baseline identity count changed: {path}"
        return data.replace(old, SERVICE.encode())
    return data


def normalized(text):
    # Comment-line/formatting normalization only; no source behavior execution.
    text = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))
    return re.sub(r"\s+", "", text)


def without_input_probe(path, data):
    if path not in ("Mac/MacSender.swift", "Mac/InputInjector.swift"):
        return data
    text = data.decode()
    text = re.sub(r"^[ \t]*// BEGIN managed-input-probe\n.*?^[ \t]*// END managed-input-probe\n",
                  "", text, flags=re.M | re.S)
    if path == "Mac/MacSender.swift":
        assert text.count(", probe: managedInputProbe") == 3
        text = text.replace(", probe: managedInputProbe", "")
    else:
        assert text.count(", probe: ManagedInputProbe? = nil") == 1
        text = text.replace(", probe: ManagedInputProbe? = nil", "")
        assert text.count("        post(event)\n") == 2
        assert text.count("        post(ev)\n") == 2
        text = text.replace("        post(event)\n", "        event.post(tap: .cghidEventTap)\n")
        text = text.replace("        post(ev)\n", "        ev.post(tap: .cghidEventTap)\n")
    return text.encode()


frozen = ["Mac/VirtualDisplay.swift", "Mac/StreamConfiguration.swift", "Mac/Usbmux.swift",
          "Mac/InputInjector.swift", "Shared/Protocol.swift", "Shared/StreamReceiver.swift",
          "SIDELINKER_FORK_RULES.md",
          "SIDELINKER_ENGINE_ARCHITECTURE.md", "SIDELINKER_ENGINE_CONTROL_PROTOCOL.md"]
tracked = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", BASE, "iOS", "Shared", ".github"], cwd=ROOT).decode().splitlines()
for path in sorted(set(frozen + tracked)):
    assert without_input_probe(path, (ROOT / path).read_bytes()) == approved_identity(path, original(path)), f"frozen path changed: {path}"
print(f"PASS: {len(set(frozen + tracked))} frozen paths unchanged except exact approved discovery-token substitutions in three paths")

# Info.plists are generated/untracked. Identity/distribution source-of-truth
# configuration must be unchanged outside the hostless Mac test target and
# precisely the three approved NSBonjourServices token substitutions.
project = (ROOT / "project.yml").read_text()
prior_project = approved_identity("project.yml", original("project.yml")).decode()
assert project[:project.index("  OpenSidecarMacTests:")] == prior_project[:prior_project.index("  OpenSidecarMacTests:")]
assert project[project.index("  OpenSidecariOS:", project.index("  OpenSidecarMacTests:")):] == prior_project[prior_project.index("  OpenSidecariOS:", prior_project.index("  OpenSidecarMacTests:")):]
print("PASS: production configuration unchanged except three approved Bonjour entries; only test target widened")

# Regression assertion on the actual browser/listener/configuration bindings,
# not just on a disconnected test constant. Does not start Network.framework.
def service_types(text):
    return re.findall(r'"(_[A-Za-z0-9-]+\._tcp)"', text)


name = SERVICE.split(".")[0][1:]
assert 1 <= len(name.encode("ascii")) <= 15
assert re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?", name)
assert re.search(r"[A-Za-z]", name) and "--" not in name
assert service_types((ROOT / "Mac/Engine/DirectEngineController.swift").read_text()) == [SERVICE]
assert service_types((ROOT / "Shared/StreamReceiver.swift").read_text()) == [SERVICE]
assert service_types(project) == [SERVICE] * 3
for path in ["Mac/Info.plist", "MacReceiver/Info.plist", "iOS/Info.plist"]:
    with (ROOT / path).open("rb") as file:
        assert plistlib.load(file)["NSBonjourServices"] == [SERVICE], f"generated Bonjour binding drift: {path}"
print("PASS: eight-character RFC6335/RFC6763 service name and matching browser/listener/three generated plist bindings")

stale = subprocess.run(["rg", "--hidden", "--no-ignore", "--glob", "!.git/**",
                        "--fixed-strings", "--count-matches", bootstrap_service, "."],
                       cwd=ROOT, capture_output=True, text=True)
assert stale.returncode == 1 and not stale.stdout, f"stale token matches or search error: {stale.stdout}{stale.stderr}"
print("PASS: zero stale service-token matches in entire working repository, including ignored/generated files (Git history excluded)")

old = original("Mac/OpenSidecarMacApp.swift").decode()
ui = (ROOT / "Mac/StandaloneSenderUI.swift").read_text()
start = "@MainActor\nfinal class PermissionMonitor"
assert normalized(old[old.index(start):]) == normalized(ui[ui.index(start):]), "standalone UI behavior changed"
print("PASS: relocated standalone permission/views code matches baseline after comment/whitespace normalization")

engine = (ROOT / "Mac/Engine/DirectEngineController.swift").read_text()
server = (ROOT / "Mac/Engine/LocalControlServer.swift").read_text()
app = (ROOT / "Mac/OpenSidecarMacApp.swift").read_text()
assert "import SwiftUI" not in engine and "SenderController" not in engine and "MainWindow" not in engine
assert "if managed { recoverManagedSession(); return }" in engine
assert "guard !managed else { return }" in engine
assert "grant.stop() // Revoke BEFORE teardown" in engine
assert "self.grant.permitsRecovery(generation: generation)" in engine
assert "self.isCurrent(session)" in engine
assert "getpeereid" in server and "uid == getuid()" in server
assert "socket(AF_UNIX, SOCK_STREAM, 0)" in server
assert not re.search(r"AF_INET|NWListener|localhost|127\.0\.0\.1", server)
assert "!EngineLaunch.managed && controller.presentation" in app
assert "NSApp.setActivationPolicy(.prohibited)" in app
assert "guard !EngineLaunch.managed else { return }" in app
assert "startingUpdater: false" in app
print("PASS: source wiring for UI-independent controller, passive discovery, revocation, same-user AF_UNIX and headless UI guards")

# Exact allowlist of the only frozen sender integration adaptations.
sender = without_input_probe("Mac/MacSender.swift", (ROOT / "Mac/MacSender.swift").read_bytes()).decode()
expected = original("Mac/MacSender.swift").decode()
changes = [
    ("    private let quality: StreamQuality\n", "    private let quality: StreamQuality\n    // Explicit managed Wi-Fi preference forbids autonomous cable migration.\n    private let wifiOnly: Bool\n"),
    ("         identityOffset: UInt32 = 0, awaitingWake: Bool = false) {", "         identityOffset: UInt32 = 0, awaitingWake: Bool = false, wifiOnly: Bool = false) {"),
    ("        self.quality = quality\n", "        self.quality = quality\n        self.wifiOnly = wifiOnly\n"),
    ("        stopped = false\n", "        // Sender instances are single-use; a delayed start must never undo stop().\n        try Task.checkCancellation()\n        guard !stopped else { throw CancellationError() }\n"),
    ("    private func startUpgradeProbing() {\n", "    private func startUpgradeProbing() {\n        guard !wifiOnly else { return }\n"),
    ("        let params = NWParameters(tls: nil, tcp: options)\n", "        let params = NWParameters(tls: nil, tcp: options)\n        if wifiOnly { params.requiredInterfaceType = .wifi }\n"),
    ("        let params = NWParameters.udp\n", "        let params = NWParameters.udp\n        if wifiOnly { params.requiredInterfaceType = .wifi }\n"),
]
for before, after in changes:
    assert expected.count(before) == 1
    expected = expected.replace(before, after)
assert sender == expected, "sender changed outside seven bounded lifecycle/configuration integrations"
print("PASS: exact seven sender adaptation allowlist; capture/encode/wire algorithms otherwise unchanged")
print("PASS: probe-stripped sender/injector preserve baseline input behavior and AX wait; probe diagnostics require separate review")
subprocess.run(["git", "diff", "--check"], cwd=ROOT, check=True)
print("PASS: git diff --check")
