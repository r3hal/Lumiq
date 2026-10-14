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
assert not run('git','diff','--name-only','--','Focal/Sony').strip(),'Sony connectivity changed'
run('git','diff','--check')
count=sum(len(re.findall(r'func test\w+\(',p.read_text())) for p in tests)
assert count==314,count
print(f'PASS: deterministic project; {len(app)} app/{len(tests)} test Swift references; lexical delimiters; plist/XML/JSON/assets; YAML/build shell syntax; original baseline hashes; Sony source unchanged; whitespace.')
print(f'REGISTERED: {count} XCTest functions. Not executed. Swift grammar/type checking and native build remain pending.')
