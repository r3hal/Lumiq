#!/usr/bin/env python3
"""Explicit integration source/build/privacy boundaries; not hardware proof."""
import hashlib
import json
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]
def read(path): return (ROOT/path).read_text()
audit = json.loads(read('docs/FOCAL_3_0_SOURCE_AUDIT.json'))
assert audit['baselineCommit'] == '61753417d76de4571d741412b7f161d72feead5d'
for path, expected in audit['preservedSHA256'].items():
    assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest() == expected, path
for path, values in audit['reviewedSources'].items():
    assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest() == values['after'], path
controller = read('Focal/Camera/CameraController.swift')
assert 'deadline:observationTime + GuidanceObservationPolicy.maximumAge' in controller
assert 'trackingReference:tracker.trackingReference) : nil' in controller
assert '(framing.shotVerified || framing.currentFrameVerified)' in controller
assert 'self?.handleSessionInterruption()' in controller
assert 'self.framing.reset(enabled:false); self.publishFraming()' not in controller.split('func selectLens(')[1].split('private func updateManualControls(')[0]
assert 'Button(action: shoot)' in read('Focal/Camera/CameraView.swift')
proxy = read('Focal/Cloud/CloudCompositionProxyService.swift')
assert 'Authorization' in proxy and 'Idempotency-Key' in proxy
assert 'BackupKeychain' not in proxy and 'GeminiCloudConfiguration' not in proxy
assert 'print(' not in proxy
workflows = yaml.safe_load(read('codemagic.yaml'))['workflows']
for name in ('ios-sideload','ios-debug-sideload','ios-evaluation'):
    workflow = workflows[name]
    assert not workflow['environment'].get('groups')
    assert any('scripts/package_public_ipa.py' in step['script'] for step in workflow['scripts'])
    assert all('*' not in path and 'private' not in path.lower() for path in workflow['artifacts'])
assert 'artifacts' not in workflows['ios-cloud-personal']
assert len(audit['preservedSHA256']) > 30
print(f'PASS: Focal 3 reviewed source boundaries, {len(audit["preservedSHA256"])} preserved files, inference admission, lifecycle, public artifacts, independent proxy authorization and manual shutter guards.')
