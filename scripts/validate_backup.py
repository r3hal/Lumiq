#!/usr/bin/env python3
"""Source/configuration guards, not a native build or device test."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
def read(path): return (ROOT/path).read_text()
manifest = json.loads(read('docs/PHOTO-BACKUP-PRESERVED-SOURCES.json'))
for path, expected in manifest['sha256'].items():
    assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest() == expected, f'Protected source changed: {path}'
backup = '\n'.join(p.read_text() for p in (ROOT/'Focal/Backup').glob('*.swift'))
assert all(word not in backup for word in ['capturePhoto(', 'ramp(toVideoZoomFactor:', 'startRunning(', 'GoogleSignIn', 'GeminiCloudCompositionService'])
assert 'print(' not in backup and 'Logger(' not in backup
library = read('Focal/Library/PhotoLibrary.swift')
assert library.index('try persist(next)\n            photos = next') < library.index('backupCoordinator?.saved(photo)')
assert library.index('photo.backupEnrollment =') < library.index('let capturedFiles = files')
assert 'weak var backupCoordinator:' in library
coordinator = read('Focal/Backup/PhotoBackupCoordinator.swift')
assert 'photo.cameraOrigin == CameraSource.iPhone.rawValue' in coordinator
assert 'Task.detached(priority:.utility)' in coordinator
assert 'metadata.backupEnrollment = nil' in coordinator
background = read('Focal/Backup/BackupBackgroundSession.swift')
assert 'uploadTask(with:transfer.request,fromFile:transfer.file)' in background
assert 'allowsCellularAccess = true' in background and 'sessionSendsLaunchEvents = true' in background
assert 'completionHandler(nil)' in background and 'self.group.leave()' in background
assert 'kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly' in read('Focal/Backup/BackupKeychain.swift')
info = plistlib.loads((ROOT/'Focal/Resources/Info.plist').read_bytes())
assert 'NSAllowsArbitraryLoads' not in str(info) and 'UIBackgroundModes' not in info
privacy = plistlib.loads((ROOT/'Focal/Resources/PrivacyInfo.xcprivacy').read_bytes())
assert any(p['NSPrivacyAccessedAPIType'] == 'NSPrivacyAccessedAPICategoryDiskSpace' and 'E174.1' in p['NSPrivacyAccessedAPITypeReasons'] for p in privacy['NSPrivacyAccessedAPITypes'])
tracked = subprocess.check_output(['git','ls-files'],cwd=ROOT,text=True).splitlines()
assert 'backup-server/.env' not in tracked and not any(p.startswith('backup-server/data/') for p in tracked)
assert '.env' in read('backup-server/.dockerignore')
assert '--no-access-log' in read('backup-server/Dockerfile')
assert 'https://www.googleapis.com/auth/drive.file' in read('backup-server/focal_backup/google_drive.py')
assert 'code_challenge_method' in read('backup-server/focal_backup/google_drive.py')
assert 'focal-data:/data' in read('backup-server/compose.yaml')
assert 'ports:' not in read('backup-server/compose.yaml').split('  https:')[0]
print(f'PASS: {len(manifest["sha256"])} protected camera/AI/Gemini/Sony/editor source hashes; post-commit enrollment; file-backed cellular/background integration; consent/Keychain/privacy/secret and deployment guards. Not native execution.')
