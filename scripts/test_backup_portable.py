#!/usr/bin/env python3
"""Compile real backup core and fixture tests without Apple frameworks.

Linux uses OpenSSL solely as the test harness's implementation of the platform
SHA-256 adapter. iOS production uses CryptoKit; Keychain/OS background execution
and SwiftUI require the separate native CI/device checks.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--swift', default='swift')
parser.add_argument('--build-only', action='store_true')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='focal-backup-') as directory:
    work = Path(directory)
    app, tests, crypto = work/'Sources/Focal', work/'Tests/FocalTests', work/'Sources/BackupTestCrypto'
    for p in [app, tests, crypto/'include']:
        p.mkdir(parents=True)
    (work/'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name:"FocalBackup",products:[.library(name:"Focal",targets:["Focal"])],targets:[
 .target(name:"BackupTestCrypto",linkerSettings:[.linkedLibrary("crypto")]),
 .target(name:"Focal",dependencies:["BackupTestCrypto"]),
 .testTarget(name:"FocalTests",dependencies:["Focal"])])
''')
    (crypto/'include/BackupTestCrypto.h').write_text('''#include <stdint.h>
int focal_backup_hash_file(const char *path, char *hex, int64_t *size);
''')
    (crypto/'hash.c').write_text('''#include "BackupTestCrypto.h"
#include <stdio.h>
#include <openssl/evp.h>
int focal_backup_hash_file(const char *path, char *hex, int64_t *size) {
 FILE *f=fopen(path,"rb"); if(!f)return 0;
 EVP_MD_CTX *ctx=EVP_MD_CTX_new(); if(!ctx){fclose(f);return 0;}
 int ok=EVP_DigestInit_ex(ctx,EVP_sha256(),NULL); *size=0;
 unsigned char buffer[65536],out[EVP_MAX_MD_SIZE];size_t count;unsigned int n=0;
 while(ok && (count=fread(buffer,1,sizeof(buffer),f))>0){*size+=count;ok=EVP_DigestUpdate(ctx,buffer,count);}
 if(ferror(f))ok=0;if(ok)ok=EVP_DigestFinal_ex(ctx,out,&n);fclose(f);EVP_MD_CTX_free(ctx);
 if(!ok || n!=32)return 0;for(unsigned int i=0;i<n;i++)sprintf(hex+i*2,"%02x",out[i]);hex[64]=0;return 1;
}
''')
    for name in ['BackupModels', 'BackupDiskStore', 'BackupNetworking', 'BackupEngine', 'BackupBackgroundSession']:
        shutil.copyfile(ROOT/f'Focal/Backup/{name}.swift', app/f'{name}.swift')
    for name in ['PhotoBackupTests.swift']:
        shutil.copyfile(ROOT/'FocalTests'/name, tests/name)
    env = os.environ.copy()
    env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(work/'module-cache')
    print('Testing production backup core with local fixtures only:', work, flush=True)
    result = subprocess.run([args.swift, 'build' if args.build_only else 'test', '--package-path', str(work), '--jobs', '2'], env=env)
    raise SystemExit(result.returncode)
