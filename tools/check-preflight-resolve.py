#!/usr/bin/env python3
"""Run the entire production holder/C callback with synthetic imported APIs.

Real serial queue, cancellation and five-second timer; synthetic Network/DNS
boundaries permit exact indices without private NWInterface constructors.
"""
import argparse
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--artifacts', type=Path, required=True)
p.add_argument('--negative-control', action='store_true')
p.add_argument('--reply', action='store_true', help='Run exact-size post-reply holder checks instead of DNS stream checks')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
out = a.artifacts / ('reply-negative' if a.reply and a.negative_control else 'reply' if a.reply else 'resolve-negative' if a.negative_control else 'resolve')
out.mkdir(parents=True, exist_ok=True)
text = (root / 'Mac/Engine/ReceiverPreflight.swift').read_text()
if a.negative_control and not a.reply:
    needle = 'guard let matched else { return }'
    assert text.count(needle) == 1
    text = text.replace(needle, 'guard let matched else { holder.fail(PreflightWire.failure("routeUnavailable")); return }')
elif a.negative_control:
    needle = 'self.phase = .prepared'
    assert text.count(needle) == 1
    text = text.replace(needle, needle + '\n                self.fail(PreflightWire.failure("cancelled")); return')
for name in ['NWInterface', 'NWBrowser', 'NWParameters', 'NWConnection', 'NWEndpoint',
             'DNSServiceResolve', 'DNSServiceSetDispatchQueue', 'DNSServiceRefDeallocate', 'DNSServiceGetAddrInfo']:
    text = re.sub(r'\b' + name + r'\b', 'Fixture' + name, text)
(out / 'ReceiverPreflight.swift').write_text(text)
binary = out / 'checks'
sources = [str(out / 'ReceiverPreflight.swift'), str(root / 'tools/check-preflight-resolve.swift')]
flags = []
if a.reply:
    flags = ['-D', 'DEBUG', '-D', 'REPLY_CHECKS']
    sources += [str(root / 'tools/check-preflight-reply.swift'), str(root / 'Mac/PhoneInfo.swift'), str(root / 'Shared/Protocol.swift')]
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', *flags, *sources, '-o', str(binary)], check=True)
result = subprocess.run([str(binary)], timeout=30)
if a.negative_control:
    assert result.returncode == 1, f'Negative control did not fail assertions: {result.returncode}'
    print('EXPECTED NEGATIVE FAILURE: ' + ('post-proof local cancellation falsified' if a.reply else 'immediate foreign-interface rejection falsified'))
else:
    result.check_returncode()
