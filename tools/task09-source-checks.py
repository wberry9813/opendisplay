#!/usr/bin/env python3
"""Task09 source/frozen-boundary evidence, NOT runtime/media verification."""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = "7f67f64e63cc5098dac114325e75986e2ca89b00"


def original(path):
    return subprocess.check_output(["git", "show", f"{BASE}:{path}"], cwd=ROOT)


def normalized(text):
    # Comment-line/formatting normalization only; no source behavior execution.
    text = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))
    return re.sub(r"\s+", "", text)


frozen = ["Mac/VirtualDisplay.swift", "Mac/StreamConfiguration.swift", "Mac/Usbmux.swift",
          "Mac/InputInjector.swift", "Shared/Protocol.swift", "Shared/StreamReceiver.swift",
          "SIDELINKER_FORK_RULES.md",
          "SIDELINKER_ENGINE_ARCHITECTURE.md", "SIDELINKER_ENGINE_CONTROL_PROTOCOL.md"]
tracked = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", BASE, "iOS", "Shared", ".github"], cwd=ROOT).decode().splitlines()
for path in sorted(set(frozen + tracked)):
    assert (ROOT / path).read_bytes() == original(path), f"frozen path changed: {path}"
print(f"PASS: {len(set(frozen + tracked))} frozen media/receiver/identity/distribution/contract paths byte-identical")

# Info.plists are generated/untracked. Identity/distribution source-of-truth
# configuration must be unchanged outside the hostless Mac test target.
project = (ROOT / "project.yml").read_text()
prior_project = original("project.yml").decode()
assert project[:project.index("  OpenSidecarMacTests:")] == prior_project[:prior_project.index("  OpenSidecarMacTests:")]
assert project[project.index("  OpenSidecariOS:", project.index("  OpenSidecarMacTests:")):] == prior_project[prior_project.index("  OpenSidecariOS:", prior_project.index("  OpenSidecarMacTests:")):]
print("PASS: all production target bundle/Bonjour/distribution configuration unchanged; only test target widened")

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
sender = (ROOT / "Mac/MacSender.swift").read_text()
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
subprocess.run(["git", "diff", "--check"], cwd=ROOT, check=True)
print("PASS: git diff --check")
