#!/usr/bin/env python3
"""Real public NWBrowser results + exact controller callback and whole holder.

DNS/TCP are synthetic boundaries. No Product/iPad action or real media connection.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--artifacts', type=Path, required=True)
p.add_argument('--negative-control', choices=['full-result', 'ignore-removal'])
p.add_argument('--interface-a', default='en5')
p.add_argument('--interface-b', default='en1')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
out = a.artifacts / ('route-' + (a.negative_control or 'positive'))
out.mkdir(parents=True, exist_ok=False)
source = (root / 'Mac/Engine/DirectEngineController.swift').read_text()
def function(name):
    pos = source.index('func ' + name)
    start = source.rfind('\n', 0, pos) + 1
    opening = source.index('{', pos)
    depth, i = 1, opening + 1
    while depth:
        depth += (source[i] == '{') - (source[i] == '}')
        i += 1
    return source[start:i] + '\n'
names = ['preflightRoute', 'samePreflightRoute', 'retireWithdrawnPreparation',
         'cancelAllPreparations', 'receivedBonjourResults']
parts = {n: function(n) for n in names}
parts['preflightRoute'] = parts['preflightRoute'].replace('func preflightRoute(', 'func observedPreflightRoute(')
controller = '''import Foundation
import Network
final class RouteController {
    var discovered: [NWBrowser.Result] = []
    var usbDevices: [UsbmuxDevice] = []
    var installIDByUDID: [String:String] = [:]
    var preparation: (holder: ReceiverPreflightHolder, cancelling: Bool)?
    var freshOverride: PreflightRoute?
    func preflightRoute(receiverID: String, preference: EngineTransportPreference) throws -> PreflightRoute {
        if let freshOverride { return freshOverride }
        return try observedPreflightRoute(receiverID: receiverID, preference: preference)
    }
    func txtID(of result: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = result.metadata { return txt["id"] }; return nil
    }
    func diagnoseBonjour(_ results: [NWBrowser.Result]) {}
    func endSessionsWhoseServiceVanished() {}
    func autoConnect() {}
    func connectNewlyCabled() {}
    func publishSnapshots() {}
    func compare(_ a: PreflightRoute, _ b: PreflightRoute, pin: NWInterface?) -> Bool {
        samePreflightRoute(a, b, pinnedInterface: pin)
    }
''' + ''.join(parts[n] for n in names) + '}\n'
if a.negative_control == 'full-result':
    old = parts['samePreflightRoute']
    mutant = '''    private func samePreflightRoute(_ left: PreflightRoute, _ right: PreflightRoute,
        pinnedInterface: NWInterface?) -> Bool {
        switch (left, right) {
        case (.usb(let a, let ai), .usb(let b, let bi)): return a == b && ai == bi
        case (.network(let a, let aw), .network(let b, let bw)): return a == b && aw == bw
        default: return false
        }
    }
'''
    controller = controller.replace(old, mutant)
elif a.negative_control == 'ignore-removal':
    needle = 'original.contains(interface) && b.interfaces.contains(interface)'
    assert controller.count(needle) == 1
    controller = controller.replace(needle, 'original.contains(interface)')
(out / 'RouteController.swift').write_text(controller)
holder = (root / 'Mac/Engine/ReceiverPreflight.swift').read_text()
for n in ['NWConnection', 'DNSServiceResolve', 'DNSServiceSetDispatchQueue',
          'DNSServiceRefDeallocate', 'DNSServiceGetAddrInfo']:
    holder = re.sub(r'\b' + n + r'\b', 'Fixture' + n, holder)
(out / 'ReceiverPreflight.swift').write_text(holder)
(out / 'main.swift').write_bytes((root / 'tools/check-preflight-route.swift').read_bytes())
(out / 'extraction.json').write_text(json.dumps(dict(
    functions={n: hashlib.sha256(function(n).encode()).hexdigest() for n in names},
    controller_sha256=hashlib.sha256(source.encode()).hexdigest(),
    holder_sha256=hashlib.sha256((root / 'Mac/Engine/ReceiverPreflight.swift').read_bytes()).hexdigest(),
    negative_control=a.negative_control,
    limits='Actual Result/endpoint/TXT/interface equality; exact extracted callback/decision/cancel; whole holder and PhoneInfo. Synthetic DNS/TCP; policy override; unrelated controller effects stubbed.'), indent=2))
commands = [(['xcrun', 'swiftc', '-swift-version', '5', '-D', 'DEBUG', str(out / 'main.swift'),
    str(out / 'RouteController.swift'), str(out / 'ReceiverPreflight.swift'),
    str(root / 'Mac/Engine/DirectIdentityDiagnostics.swift'), str(root / 'Mac/PhoneInfo.swift'),
    str(root / 'Shared/Protocol.swift'), '-o', str(out / 'checks')], 'compile'),
    ([str(out / 'checks'), a.interface_a, a.interface_b], 'run')]
for command, name in commands:
    print('START', name, flush=True)
    with (out / (name + '.log')).open('x') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=150)
    print('END', name, result.returncode, flush=True)
    if name == 'run' and a.negative_control:
        text = (out / 'run.log').read_text()
        expected = 'route verdict additive' if a.negative_control == 'full-result' else 'route verdict A-removed'
        assert result.returncode != 0 and expected in text, text
        print('EXPECTED NEGATIVE FAILURE:', expected)
    else:
        result.check_returncode()
