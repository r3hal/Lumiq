#!/usr/bin/env python3
"""Run production Foundation framing logic on Linux. Does not build AVFoundation/SwiftUI.

Whole production algorithm files are copied unchanged. Supporting declarations
are sliced verbatim from their original Swift files to avoid Apple-only image
sampling dependencies. No fake camera implementation is used. --baseline REF
runs the same video regressions against the previous source snapshot.
"""
import argparse,os,re,shutil,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--swift',default='swift');p.add_argument('--baseline');args=p.parse_args()
def source(path):
 return subprocess.check_output(['git','show',f'{args.baseline}:{path}'],cwd=ROOT,text=True) if args.baseline else (ROOT/path).read_text()
def declaration(path,name):
 text=source(path); match=re.search(r'^(?:struct|enum) '+re.escape(name)+r'\b',text,re.M)
 if not match:raise ValueError(name)
 start=match.start();brace=text.index('{',start);depth=1;i=brace+1
 # These data declarations have balanced interpolation; preserve exact source.
 while depth:
  if text[i]=='{':depth+=1
  elif text[i]=='}':depth-=1
  i+=1
 return text[start:i]
work=Path(tempfile.mkdtemp(prefix='focal-framing-'));app=work/'Sources/Focal';tests=work/'Tests/FocalTests';app.mkdir(parents=True);tests.mkdir(parents=True)
(work/'Package.swift').write_text('// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name:"FocalFraming",products:[.library(name:"Focal",targets:["Focal"])],targets:[.target(name:"Focal"),.testTarget(name:"FocalTests",dependencies:["Focal"])])\n')
if args.baseline:
 whole=['CompositionEngine','FramingPlanner','AutomaticShotPlan','PreviewProjection','CompositionLibrary','FramingProgress']
else:
 whole=['CompositionEngine','FramingPlanner','AutomaticShotPlan','PreviewProjection','CompositionLibrary','FramingProgress',
        'AutomaticGuidance','CompositionAssessment','GuidanceTimingAccumulator','IntentCompositionSearch','PetFramingStyle',
        'PhotographicReasoner','PhotographyIntent','RecommendationMemory','SceneCompositionEvidence','SceneCompositionPlanner',
        'ShotReadiness','SubjectIdentity','SubjectSelection','TargetRectangleGeometry','TargetRectangleSearch','GuidanceObservation']
for name in whole:
 text=source(f'Focal/Composition/{name}.swift')
 if name=='GuidanceObservation':text=text.split('#if DEBUG || FOCAL_EVALUATION')[0]
 (app/(name+'.swift')).write_text(text)
(app/'ShotCaptureSession.swift').write_text(source('Focal/Camera/ShotCaptureSession.swift'))
(app/'CameraTelemetry.swift').write_text(source('Focal/Camera/CameraTelemetry.swift'))
if not args.baseline:(app/'CameraControls.swift').write_text(source('Focal/Camera/CameraControls.swift'))
if not args.baseline:
 # Copy the original model and pure luma implementation verbatim, excluding its
 # CoreVideo/CoreImage/ImageIO adapters (not available on Linux).
 text=source('Focal/Composition/PhotoMeasurements.swift')
 text='import Foundation\n'+text[text.index('struct PhotoMeasurements'):text.index('    static func from(buffer:')]+"}\n"
 (app/'PhotoMeasurements.swift').write_text(text)
else:
 parts=['import Foundation']
 for path,names in {
  'Focal/Composition/SceneCompositionPlanner.swift':['CompositionOption','SceneCompositionPlan'],
  'Focal/Composition/CompositionAssessment.swift':['SubjectAnatomy'],
  'Focal/Composition/ShotReadiness.swift':['ShotDirectorState','CameraZoomObservation'],
  'Focal/Composition/SubjectIdentity.swift':['CompositionCue'],
  'Focal/Composition/GuidanceObservation.swift':['GuidanceObservationPolicy'],
 }.items():
  for name in names:parts.append(declaration(path,name))
 constant=re.search(r'    static let minimumImprovement = [0-9.]+',source('Focal/Composition/IntentCompositionSearch.swift')).group()
 parts.append('enum IntentCompositionSearch {\n'+constant+'\n}')
 (app/'SupportingDeclarations.swift').write_text('\n\n'.join(parts)+'\n')
# Tests remain the same source used by Xcode; baseline runs only the video cases.
for name in (['FramingVideoRegressionTests'] if args.baseline else ['FramingVideoRegressionTests','FramingProgressionTests','FramingPlannerTests','TargetRectangleDirectorTests']):
 shutil.copyfile(ROOT/'FocalTests'/f'{name}.swift',tests/f'{name}.swift')
if not args.baseline:
 shutil.copyfile(ROOT/'FocalTests/AutomaticShotFramingTests.swift',tests/'AutomaticShotFramingTests.swift')
if not args.baseline:
 shutil.copyfile(ROOT/'FocalTests/Intelligence30Tests.swift',tests/'Intelligence30Tests.swift')
 # Execute unchanged pure test bodies from the mixed Apple/platform files.
 for name in ['IntelligenceAcceptanceTests','Intelligence40Tests','GuidanceRefinementTests']:
  text=(ROOT/'FocalTests'/f'{name}.swift').read_text().split('#if DEBUG || FOCAL_EVALUATION')[0]
  text=text.replace('import UIKit\n','')
  rejected=[]
  for match in re.finditer(r'    (?:private )?func \w+\(',text):
   start=match.start();brace=text.index('{',start);depth=1;i=brace+1
   while depth:
    if text[i]=='{':depth+=1
    elif text[i]=='}':depth-=1
    i+=1
   body=text[start:i]
   if any(token in body for token in ['UIImage','CameraSettings','PreviewAnalysisScheduler','AutoTune','Baseline','Evaluation','SonyEndpoint']):rejected.append((start,i))
  for start,end in reversed(rejected):text=text[:start]+text[end:]
  text=text.replace('    @MainActor\n','')
  (tests/f'{name}.swift').write_text(text)
env=os.environ.copy();env['SWIFTPM_MODULECACHE_OVERRIDE']=str(work/'module-cache')
print(f'Production framing tests: {work}; baseline={args.baseline or "working tree"}',flush=True)
result=subprocess.run([args.swift,'test','--package-path',str(work),'--jobs','2'],env=env)
raise SystemExit(result.returncode)
