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
 s=re.sub(r'(#+)"[\s\S]*?"\1','""',s)
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
# Historical local snapshots may exist without these paths in a clean clone.
# Select only a ref containing every exact source hash recorded in the manifest.
def matches_manifest(ref, hashes):
 for path,expected in hashes.items():
  result=subprocess.run(['git','show',ref+':'+path],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
  if result.returncode or hashlib.sha256(result.stdout).hexdigest()!=expected:return False
 return True
ref30=next((ref for ref in [manifest30['localSnapshotCommit'],manifest30['commit']] if matches_manifest(ref,manifest30['sha256'])),None)
assert ref30 is not None,'No available commit matches the original baseline-30 source hashes'
for path,expected in manifest30['sha256'].items():
 original=subprocess.check_output(['git','show',ref30+':'+path],cwd=ROOT)
 assert hashlib.sha256(original).hexdigest()==expected,path
# AI guidance is the authorized scope; protect the working Sony integration.
assert not run('git','diff','HEAD','--name-only','--','Focal/Sony').strip(),'Sony integration changed'
run('git','diff','--check')
count=sum(len(re.findall(r'func test\w+\(',p.read_text())) for p in tests)
assert count==712,count
print(f'PASS: deterministic project; {len(app)} app/{len(tests)} test Swift references; no duplicate module-level types; lexical delimiters; plist/XML/JSON/assets; YAML/build shell syntax; original baseline hashes; Sony sources unchanged; whitespace.')
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

# One Sony monitor owns background reads; refreshing must not globally disable controls.
sony=(ROOT/'Focal/Sony/SonyRemoteCamera.swift').read_text()
assert len(re.findall(r'monitorTask = Task \{',sony))==1
assert 'guard monitorTask == nil else { return }' in sony
assert 'refreshTask' not in sony and 'remoteSettings = [:]' not in sony
busy=re.search(r'var controlsBusy: Bool \{([^\n]+)',sony).group(1)
assert 'isRefreshingSettings' not in busy

# Continuous guidance: manual zoom suspends only the motor, and both gesture
# end and capture completion must have their production integration wired.
assert 'automaticShotArmed = false' not in controller
assert 'framing.stop(reason:manualOverride' not in controller
assert 'evaluatedAt >= analysisManualZoomUntil' in controller
manual_replan=controller.split('private func replanAfterManualFraming()')[1].split('private func publishFraming()')[0]
assert 'tracker.reset()' not in manual_replan and 'subjectAutofocus.reset()' not in manual_replan
preview=(ROOT/'Focal/Camera/CameraPreview.swift').read_text()
assert 'view.finishPinch()' in preview and 'onPinchEnd?()' in preview
assert re.search(r'onPinchEnd:\s*\{\s*camera.endManualZoom\(\)\s*\}',cameraView)
finish=controller.split('private func finishCapture(')[1]
assert 'self.replanAfterManualFraming()' in finish and 'self.wantsScan = true' in finish
assert 'framing.shotPlan?.sceneAnchor != true' in controller
print('PASS: manual motor grace/gesture-end/capture-resumption/scene-only integration guards (source checks, not device execution).')

# Whole-scene presentation must carry actual director verification, rather than
# treating every unconfirmed READY object reading as a ready landscape.
assert 'result.sceneFrameVerified = framing.currentFrameVerified && framing.shotPlan?.sceneAnchor == true' in controller
guide=(ROOT/'Focal/Camera/CameraGuidanceCard.swift').read_text()
assert 'reading.sceneFrameVerified,message.kind == .ready,reading.state == .ready,phase == .framed' in guide

# Experimental cloud scan must not acquire credentials from tracked files or
# connect the cloud service to readiness/shutter polling. These are source guards.
tracked=run('git','ls-files').splitlines()
assert not any(path.startswith('LocalDeveloper/') or path.endswith('CloudComposition.local.json') for path in tracked)
example=json.loads((ROOT/'DeveloperExamples/CloudComposition.example.json').read_text())
assert example['apiKey']=='REPLACE_LOCALLY_DO_NOT_COMMIT'
cloud_files=list((ROOT/'Focal/Cloud').glob('*.swift'))
cloud_text='\n'.join(p.read_text() for p in cloud_files)
assert 'x-goog-api-key' in cloud_text and '?key=' not in cloud_text
assert 'print(' not in cloud_text and 'Logger(' not in cloud_text
assert 'capturePhoto(' not in cloud_text and 'shoot(' not in cloud_text
assert 'streamGenerateContent' not in cloud_text and 'service.scan(capture)' not in controller
# Accepted old scans must not invalidate a newer scan/camera session.
cloud_accept=controller.split('func applyCloudComposition(')[1].split('private func publishCloudCompositionStatus(')[0]
assert 'invalidateGuidanceResults(' not in cloud_accept
assert 'self.resultGate.invalidate(at:now)' in cloud_accept
# Cloud recovery cannot accumulate local READY proof against a replacement.
assert 'framing.confirmCurrentFrame(eligible:!cloudRecovering && (' in controller
assert 'retaining:!cloudRecovering && (' in controller
# The locked subject must be retained even with Auto Zoom and subject AF off.
retention=controller.split('let keepFramedSubject =')[1].split('let inferenceStarted =')[0]
assert '&& (cloudCompositionLock != nil || framing.shotPlan != nil && framing.phase.isPreparing' in retention
assert 'reacquisitionGrace:analysisSource == .iPhone && (cloudCompositionLock != nil || framing.shotPlan != nil || subjectAutofocus.identity != nil)' in controller
assert 'Cloud AI Scan (Experimental)' in cameraView
assert 'CloudComposition.local.json' not in (ROOT/'Focal/Resources/Info.plist').read_text()
print('PASS: explicit experimental scan integration, tracked-secret exclusion, bounded HTTPS service and user-only shutter source guards.')

# Personal cloud builds use temporary SSH delivery, never persistent key-bearing artifacts.
personal=config['workflows']['ios-cloud-personal']
assert 'artifacts' not in personal
assert all(key not in personal for key in ('triggering','publishing','cache'))
assert personal['environment']['groups']==['focal_cloud_personal']
assert 'GEMINI_API_KEY' not in personal['environment'].get('vars',{})
assert personal['environment']['vars']['GEMINI_MODEL']=='gemini-3.8-flash'
personal_scripts='\n'.join(step['script'] for step in personal['scripts'])
assert 'env -u GEMINI_API_KEY xcodebuild' in personal_scripts
assert 'python3 scripts/build_personal_cloud_ipa.py build' in personal_scripts
private_builder=(ROOT/'scripts/build_personal_cloud_ipa.py').read_text()
assert '"-configuration", "Debug"' in private_builder
assert 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG' not in private_builder
assert '"x-goog-api-key": configuration.api_key' in private_builder
assert 'public_environment()' in private_builder and 'NoRedirect' in private_builder
assert 'wait_for_download(output, sha)' in private_builder
assert 'CM_EXPORT_DIR' in private_builder and 'CM_TRIGGER_SOURCE' in private_builder
assert not re.search(r'(?i)(print|logger)\(.*(api_key|configuration\.json)',private_builder)
assert all('focal_cloud_personal' not in w.get('environment',{}).get('groups',[]) for n,w in config['workflows'].items() if n!='ios-cloud-personal')
print('PASS: private manual Debug workflow; app-scoped secret group; sanitized child environment; temporary SSH delivery with no artifact/publishing/cache paths.')
