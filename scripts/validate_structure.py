#!/usr/bin/env python3
"""Check project/data structure. This does NOT parse/type-check or build Swift."""
from pathlib import Path
import hashlib,json,plistlib,re,subprocess,tempfile,xml.etree.ElementTree as ET
import yaml
ROOT=Path(__file__).resolve().parents[1]
def run(*args): return subprocess.check_output(args,cwd=ROOT,text=True)
project=ROOT/'Focal.xcodeproj/project.pbxproj'
first=project.read_bytes();run('python3','scripts/generate_project.py');assert project.read_bytes()==first,'Project generation is not deterministic'
app=list((ROOT/'Focal').rglob('*.swift'));tests=list((ROOT/'FocalTests').glob('*.swift'))
# This source-style check catches copied module-level types before Xcode.
# It deliberately does not claim to parse all Swift syntax/conditional branches.
declarations={}
pattern=r'^(?:(?:private|fileprivate|internal|public|final|indirect)\s+)*(?:struct|enum|class|actor|protocol|typealias)\s+(\w+)'
for p in app:
 for name in re.findall(pattern,p.read_text(),re.M):
  declarations.setdefault(name,[]).append(str(p.relative_to(ROOT)))
collisions={name:paths for name,paths in declarations.items() if len(paths)>1}
assert not collisions,f'Duplicate module-level type declarations: {collisions}'
text=project.read_text()
for p in app+tests: assert str(p.relative_to(ROOT)) in text,p
for p in ROOT.rglob('*.json'):
 if '.git' not in p.parts: json.loads(p.read_text())
for p in list((ROOT/'Focal/Resources').rglob('*.plist'))+list((ROOT/'Focal/Resources').rglob('*.xcprivacy')):
 plistlib.loads(p.read_bytes())
for p in (ROOT/'Focal.xcodeproj').rglob('*.xcscheme'): ET.parse(p)
config=yaml.safe_load((ROOT/'codemagic.yaml').read_text())
for workflow in config['workflows'].values():
 for step in workflow.get('scripts',[]):
  subprocess.run(['bash','-n'],input=step['script'],text=True,check=True)
for p in (ROOT/'Focal/Resources/Assets.xcassets').rglob('Contents.json'):
 for entry in json.loads(p.read_text()).get('images',[]):
  if entry.get('filename'):assert (p.parent/entry['filename']).is_file(),p
# Lexical delimiter audit only: strips literals/comments, not Swift grammar.
for p in app+tests:
 s=p.read_text();s=re.sub(r'/\*.*?\*/','',s,flags=re.S)
 s=re.sub(r'""".*?"""','""',s,flags=re.S)
 s=re.sub(r'"(?:\\.|[^"\\])*"','""',s,flags=re.S)
 s=re.sub(r'//[^\n]*','',s)
 stack=[];close={')':'(',']':'[','}':'{'}
 for c in s:
  if c in '([{':stack.append(c)
  elif c in close:assert stack and stack.pop()==close[c],(p,c)
 assert not stack,(p,stack)
manifest=json.loads((ROOT/'docs/intelligence/BASELINE-22-SOURCES.json').read_text())
baselineRef=next(ref for ref in [manifest['publishedCommit'],manifest['localSnapshotCommit']] if subprocess.run(['git','cat-file','-e',ref+'^{commit}'],cwd=ROOT,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0)
for path,expected in manifest['originalSourceSHA256'].items():
 original=subprocess.check_output(['git','show',baselineRef+':'+path],cwd=ROOT)
 assert hashlib.sha256(original).hexdigest()==expected,path
manifest30=json.loads((ROOT/'docs/intelligence/BASELINE-30-SOURCES.json').read_text())
ref30=manifest30['localSnapshotCommit']
for path,expected in manifest30['sha256'].items():
 original=subprocess.check_output(['git','show',ref30+':'+path],cwd=ROOT)
 assert hashlib.sha256(original).hexdigest()==expected,path
assert not run('git','diff','--name-only','--','Focal/Sony').strip(),'Sony connectivity changed'
run('git','diff','--check')
count=sum(len(re.findall(r'func test\w+\(',p.read_text())) for p in tests)
assert count==515,count
print(f'PASS: deterministic project; {len(app)} app/{len(tests)} test Swift references; no duplicate module-level types; lexical delimiters; plist/XML/JSON/assets; YAML/build shell syntax; original baseline hashes; Sony source unchanged; whitespace.')
print(f'REGISTERED: {count} XCTest functions. This structural check does not execute tests or establish Swift grammar/type checking or a native build; see VALIDATION.txt for separate execution evidence.')

# AI framing must never release the shutter from readiness polling.
cameraView=(ROOT/'Focal/Camera/CameraView.swift').read_text()
assert 'monitorSmartShutter' not in cameraView and 'shouldCapture(' not in cameraView
assert 'Button(action: shoot)' in cameraView
assert len(re.findall(r'\bshoot\s*\(',cameraView))==1,'Unexpected programmatic shutter trigger'

# Guard the specific controller/API integration error found in build 27.
controller=(ROOT/'Focal/Camera/CameraController.swift').read_text()
ready_calls=re.findall(r'ShotReadiness\.permitsReady\((.*?)\), result\.state',controller,re.S)
assert ready_calls and all('framingInstruction' not in call for call in ready_calls)
guidance_call=re.search(r'let message = automaticGuidance\.update\((.*?)\n        #if',controller,re.S)
assert guidance_call and 'framingInstruction:' in guidance_call.group(1)
