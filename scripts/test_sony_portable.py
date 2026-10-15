#!/usr/bin/env python3
"""Execute real Sony protocol/settings/capture policy code on Linux.
Only the unused ImageIO import is replaced by FoundationXML. No camera or iOS build.
Network tests use URLProtocol fixtures, not a physical Sony camera.
"""
from pathlib import Path
import argparse, os, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--swift',default='swift');args=p.parse_args()
work=Path(tempfile.mkdtemp(prefix='focal-sony-'));app=work/'Sources/Focal';tests=work/'Tests/FocalTests'
app.mkdir(parents=True);tests.mkdir(parents=True)
(work/'Package.swift').write_text('// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name:"FocalSony",products:[.library(name:"Focal",targets:["Focal"])],targets:[.target(name:"Focal"),.testTarget(name:"FocalTests",dependencies:["Focal"])])\n')
for name in ['SonyProtocol','SonyAPIClient','SonyControlPolicy','SonyRemoteSettings','SonyFocusWorkflow','SonyDiagnostics','SonyRemoteSnapshot']:
 text=(ROOT/f'Focal/Sony/{name}.swift').read_text().replace('import ImageIO','import FoundationXML')
 (app/f'{name}.swift').write_text(text)
(app/'CameraTelemetry.swift').write_text((ROOT/'Focal/Camera/CameraTelemetry.swift').read_text())
for name in ['SonyControlPolicyTests','SonyRemoteSettingsTests','SonyRemoteSnapshotTests']:
 (tests/f'{name}.swift').write_text((ROOT/f'FocalTests/{name}.swift').read_text())
env=os.environ.copy();env['SWIFTPM_MODULECACHE_OVERRIDE']=str(work/'module-cache')
print(f'Sony production protocol tests with scripted camera feedback: {work}',flush=True)
raise SystemExit(subprocess.run([args.swift,'test','--package-path',str(work),'--jobs','2'],env=env).returncode)
