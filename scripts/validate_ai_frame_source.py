#!/usr/bin/env python3
"""Dependency-free source/integration checks. Does not compile or execute Swift.

Run alongside native XCTest on Codemagic. --baseline verifies protected source
bytes against an explicitly selected Git commit; no historical test pass is reused.
"""
from pathlib import Path
import argparse, json, plistlib, re, subprocess, xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--baseline', required=True)
args = p.parse_args()
passed = []
def check(name, condition):
    if not condition: raise AssertionError(name)
    passed.append(name)
def read(path): return (ROOT/path).read_text(encoding='utf-8')
def method(text, name):
    match = re.search(r'\bfunc '+re.escape(name)+r'\s*\(',text)
    if not match: raise AssertionError(name)
    brace = text.index('{',match.start()); depth=1; end=brace+1
    while depth:
        if text[end]=='{':depth+=1
        elif text[end]=='}':depth-=1
        end+=1
    return text[match.start():end]

controller = read('Focal/Camera/CameraController.swift')
lens = method(controller,'selectLens')
check('lens selection replans without director OFF', 'replanAfterManualFraming()' in lens and 'framing.reset(enabled:false)' not in lens)
for name in ['beginManualZoom','setZoom','endManualZoom']:
    check(name+' preserves guide activation', 'activation.set(false)' not in method(controller,name))
check('manual acquisition grace gates detection', 'trackingOnly: zooming || rapidMovement || now < manualInferenceResumeAfter' in controller)
check('acquisition deadline derives from source observation', 'deadline:observationTime + GuidanceObservationPolicy.maximumAge' in controller)
publish = method(controller,'publishAnalysis')
check('main-queue frame publication rechecks freshness', publish.index('DispatchQueue.main.async') < publish.index('GuidanceObservationPolicy.fresh') < publish.index('update()'))
check('final guidance publication supplies source timestamp', 'publishAnalysis(snapshot,observedAt:observationTime) { self.reading = result' in controller)
check('manual layout readiness and guidance share the selected target', 'ShotReadiness.measuredManualLayout(bounds:bounds,target:manualLayoutTarget' in controller and 'let layoutTarget = manualLayout ? manualLayoutTarget' in controller and 'identity:framing.shotPlan?.sceneAnchor == true ? framing.shotPlan?.id : tracker.trackingReference' in controller)
check('motor path excludes manual layouts', 'if analysisSource == .iPhone, !manualLayout, evaluatedAt >= analysisManualZoomUntil' in controller)
check('verified current frame freezes composition choice', 'framing.shotVerified || framing.currentFrameVerified' in controller and 'plan?.selected.isCurrentFrame == true' in read('Focal/Composition/SceneCompositionPlanner.swift'))
tracker=read('Focal/Camera/SubjectTracker.swift')
check('optional request epoch is distinct from tracking', 'acquisitionRevision += 1' in tracker and 'includeTracking || !($0 is VNTrackObjectRequest)' in tracker)
check('no refreshed per-pass optional crop budget', 'systemUptime + 1.3' not in tracker)

view = read('Focal/Camera/CameraView.swift')
check('shutter remains manual', 'Button(action: shoot)' in view and len(re.findall(r'\bshoot\s*\(',view))==1 and 'monitorSmartShutter' not in view and 'shouldCapture(' not in view)
protected=['Focal/Sony/','Focal/Editing/','Focal/Library/','Focal/Camera/CameraView.swift','Focal/Camera/CameraPreview.swift','Focal/Camera/PhotoCapturePolicy.swift','Focal/Camera/SubjectAutofocus.swift']
tracked=subprocess.check_output(['git','ls-tree','-r','--name-only',args.baseline],cwd=ROOT,text=True).splitlines()
for path in tracked:
    if any(path==prefix or path.startswith(prefix) for prefix in protected):
        original=subprocess.check_output(['git','show',args.baseline+':'+path],cwd=ROOT)
        check('protected bytes: '+path,(ROOT/path).read_bytes()==original)

sources=list((ROOT/'Focal').rglob('*.swift'))+list((ROOT/'FocalTests').glob('*.swift'))
project=read('Focal.xcodeproj/project.pbxproj')
declarations={}
for path in sources:
    relative=path.relative_to(ROOT).as_posix()
    check('registered source: '+relative,relative in project)
    text=path.read_text(encoding='utf-8')
    if path.is_relative_to(ROOT/'Focal'):
        for name in re.findall(r'^(?:(?:private|fileprivate|internal|public|final|indirect)\s+)*(?:struct|enum|class|actor|protocol|typealias)\s+(\w+)',text,re.M):
            declarations.setdefault(name,[]).append(relative)
    # Lexical delimiter check only, not a Swift parser/type checker.
    text=re.sub(r'/\*.*?\*/','',text,flags=re.S)
    text=re.sub(r'""".*?"""','""',text,flags=re.S)
    text=re.sub(r'(#+)"[\s\S]*?"\1','""',text)
    text=re.sub(r'"(?:\\.|[^"\\])*"','""',text,flags=re.S)
    text=re.sub(r'//[^\n]*','',text)
    stack=[]; close={')':'(',']':'[','}':'{'}
    for char in text:
        if char in '([{':stack.append(char)
        elif char in close:
            if not stack or stack.pop()!=close[char]:raise AssertionError((relative,char))
    check('balanced lexical delimiters: '+relative,not stack)
check('no duplicate module-level types',all(len(paths)==1 for paths in declarations.values()))
for path in ROOT.rglob('*.json'):
    if '.git' not in path.parts:json.loads(path.read_text(encoding='utf-8'))
for path in list((ROOT/'Focal/Resources').rglob('*.plist'))+list((ROOT/'Focal/Resources').rglob('*.xcprivacy')):plistlib.loads(path.read_bytes())
for path in (ROOT/'Focal.xcodeproj').rglob('*.xcscheme'):ET.parse(path)
for path in (ROOT/'Focal/Resources/Assets.xcassets').rglob('Contents.json'):
    for item in json.loads(path.read_text()).get('images',[]):
        if item.get('filename'):check('asset exists: '+item['filename'],(path.parent/item['filename']).is_file())
check('JSON/plist/XML readable',True)
for document in ['FRAMED_BEHAVIOR_ANALYSIS.md','FOCAL_AI_GAP_ANALYSIS.md','FOCAL_AI_IMPROVEMENT_PLAN.md','FOCAL_AI_TEST_RESULTS.md']:
    text=read('docs/'+document)
    for target in re.findall(r'!\[[^\]]*\]\(([^)]+)\)',text):check('evidence image exists: '+target,(ROOT/'docs'/target).is_file())
subprocess.run(['git','diff','--check'],cwd=ROOT,check=True)
count=sum(len(re.findall(r'func test\w+\(',path.read_text(encoding='utf-8'))) for path in (ROOT/'FocalTests').glob('*.swift'))
print(json.dumps({'status':'PASS','scope':'source/integration structure only; Swift tests NOT executed','checks':len(passed),'swift_files':len(sources),'registered_xctest_functions':count,'protected_baseline':args.baseline},indent=2))
