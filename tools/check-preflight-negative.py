#!/usr/bin/env python3
"""Falsify the actual controller test by injecting generic start into an artifact copy.

Only the ignored generated Xcode project's file reference is temporarily redirected;
tracked source and accepted helper output are never edited. Restored in finally.
"""
import argparse
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--artifacts', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
a.artifacts.mkdir(parents=True, exist_ok=True)
source = (root / 'Mac/Engine/DirectEngineController.swift').read_text()
needle = '            let route = try preflightRoute(receiverID: receiverID, preference: preference)'
assert source.count(needle) == 1
mutant = a.artifacts / 'NegativeDirectEngineController.swift'
mutant.write_text(source.replace(needle, needle + '\n            _ = try startManagedSession(receiverID: receiverID, preference: preference)'))
project = root / 'OpenSidecar.xcodeproj/project.pbxproj'
original = project.read_text()
reference = 'path = DirectEngineController.swift; sourceTree = "<group>";'
assert original.count(reference) == 1
try:
    project.write_text(original.replace(reference, f'path = "{mutant}"; sourceTree = "<absolute>";'))
    cmd = ['xcodebuild', '-project', 'OpenSidecar.xcodeproj', '-scheme', 'OpenSidecarMac',
        '-configuration', 'Debug', '-destination', 'platform=macOS,arch=arm64',
        '-derivedDataPath', str(a.artifacts / 'EngineDerivedData'), '-jobs', '2', 'ARCHS=arm64',
        'ONLY_ACTIVE_ARCH=YES', 'CODE_SIGNING_ALLOWED=NO',
        '-only-testing:OpenSidecarMacTests/PreflightControllerTests', 'test']
    with (a.artifacts / 'engine-generic-start-negative.log').open('w') as log:
        result = subprocess.run(cmd, cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    text = (a.artifacts / 'engine-generic-start-negative.log').read_text()
    assert result.returncode != 0 and 'actualPrepareCancelExpiryNeverCreatesMedia()' in text and 'recorded an issue' in text, text[-3000:]
    print('EXPECTED NEGATIVE TEST FAILURE:', result.returncode, 'generic media start is detected by actual controller test')
finally:
    project.write_text(original)
