# Exact-folder Google Drive backup implementation

Branch: `codex/focal-exact-drive-folder`, based on the existing owner-backup branch at `6f94c379e21fc2ebf7e6de59e2be2ab9ce0d3b76`. App version **2.12.1 (40)**. [CI run 39037161938](https://github.com/r3hal/focal-private/actions/runs/39037161938) passed 713 native XCTest tests and an unsigned Release iPhone archive for source `f2e560b5d532c669c66205ab8fce753c3e4b6347`. Main, the Gemini test branch and the previous backup branch are preserved. See [deployment and Google/Windows setup](SETUP.md) and [validation evidence](VALIDATION.md).

## Audit findings and changes

The inherited implementation already saves app-private image resources and `library.json` before asynchronously enrolling a capture in its persistent queue. It uploads original bytes in file-backed background URLSession chunks to an owner backend. The backend has durable SQLite/staging, encrypted OAuth refresh tokens, per-device invitations/revocation, resumable Drive uploads, checksum verification and duplicate protection. Photos-library export is separate. Camera/AI/Gemini/Sony services are not upload triggers.

Its destination logic, however, created `Focal Photos/YYYY/MM/DD` folders. Its `drive.file` authorization did not grant an arbitrary existing folder, and completed-file verification did not check the parent. Those paths are replaced on this branch.

The server fixes its destination to **`1z7BpcVwsZAJ5ruPRHKbJ6VbnsQbOhrkU`**. There is no client-selectable folder, fallback to Drive root, or folder creation. It verifies `files.get` for that exact ID, folder MIME type, non-trashed state and `capabilities.canAddChildren` before uploading. Every `files.create` resumable request explicitly supplies that one parent. Completion requires an independent metadata read with matching ID, **exact parent**, original size, private capture/destination identity and SHA-256 (or MD5 plus size when Google omits SHA-256). No local original is removed. Only confirmed server staging is cleaned.

The owner authorizes a Web OAuth client with S256 PKCE and the limited `drive.file` scope, then explicitly selects the existing folder with Google's official Picker. OAuth alone or a folder URL cannot authorize this folder. The setup page uses a ten-minute, hashed, Secure/HttpOnly/SameSite session; writes require same origin plus a separate CSRF token. Wrong folder selections are rejected. The server rechecks Google's actual feedback rather than trusting a browser callback. Successful confirmation consumes the setup session. A Google access token is supplied only to this authenticated owner's browser because Picker requires it; refresh tokens/client secrets stay encrypted on the server. Device endpoints cannot retrieve either token. Google does not offer a literal folder-only write-only OAuth scope: server behavior enforces the narrower destination policy.

Each device still uses a revocable upload-only invitation credential in Keychain, with explicit one-time enablement and disclosure in Settings. No Google account/login is needed on test phones. The camera screen has no upload UI. Folder permission failures remain pending and display an owner-action explanation in Settings. A reconnect does not imply Drive access or successful backup. Real folder access is checked before CLI invitations and by each worker upload.

Rate limits now stay durably deferred after the bounded retry burst, with capped counters, exponential backoff and Retry-After. The phone still depends on iOS execution windows. Generic failures retain the existing bounded retry policy; owner authorization, folder access and Google quota failures retain server originals and retry slowly. No tight retry loop is introduced.

## Storage and recovery

The database is immutably bound to the exact folder. Compose uses a **new `focal-exact-folder-data` volume**, and startup refuses unbound legacy or differently bound databases. This prevents old receipts or old resumable sessions from being misrepresented as backups in the new folder. Keep an old deployment/volume for its original pending work; do not erase, relabel or silently migrate it. Explicitly enroll phones for future captures on the new destination, preferably using a separate HTTPS origin. All subsequent upgrades retain the new volume and encryption key.

Stable capture/resource IDs, server-reserved Drive IDs, durable resumable sessions and private app properties prevent ordinary retry/restart duplicates. A known or rediscovered capture moved outside the target folder fails verification rather than being duplicated or silently moved back. Same-name unrelated files are never overwritten; a deterministic suffix resolves collisions. Captured date and resource role are private metadata plus the existing sidecar, with every resource directly inside the target folder. Original HEIC/JPEG/DNG bytes and embedded metadata are not re-encoded.

## Exact files changed from the previous backup branch

App and native tests:

- `Focal/Backup/BackupEngine.swift` — folder errors and durable rate-limit deferral.
- `Focal/Backup/BackupModels.swift` — safe Settings explanations for folder access/rate limits.
- `Focal/Backup/BackupNetworking.swift` — distinguish HTTP 429 from generic service failure.
- `Focal/Backup/PhotoBackupCoordinator.swift` — keep the exact-folder error visible in Settings instead of masking it with a generic OAuth message.
- `FocalTests/PhotoBackupTests.swift` — folder failure receipt and extended rate-limit recovery tests.
- `Focal.xcodeproj/project.pbxproj` and `scripts/generate_project.py` — version 2.12.1 (40).

Backend and deployment:

- `backup-server/focal_backup/store.py` — fixed folder/database binding and short-lived owner sessions.
- `backup-server/focal_backup/google_drive.py` — access checks, direct exact-parent upload, parent verification and rate-limit recovery; removes folder creation.
- `backup-server/focal_backup/app.py` — secure owner Picker setup/confirmation and truthful connection status.
- `backup-server/focal_backup/folder.html` and `backup-server/focal_backup/folder.js` — official owner-only Google Picker integration.
- `backup-server/focal_backup/cli.py` — live `verify-folder` command and access checks before invitations.
- `backup-server/compose.yaml` — independent exact-folder data volume.
- `backup-server/.env.example` — restricted Picker key/project-number configuration, placeholders only.
- `backup-server/tests/test_backup.py` — updates existing protocol fixtures for exact parent/access checks.
- `backup-server/tests/test_exact_folder.py` — 20 additional authorization/destination/recovery fixtures.

Validation/documentation:

- `.github/workflows/photo-backup-validation.yml` — runs the existing native/archive/backend workflow for this new branch.
- `scripts/validate_backup.py` — exact-folder/no-folder-creation guards plus existing 70 protected source hashes.
- `scripts/validate_structure.py` — 713 native XCTest registration count.
- `docs/photo-backup/SETUP.md`, `IMPLEMENTATION.md`, `VALIDATION.md` — current deployment, migration, test and hardware instructions.

The post-save hook, original-resource handling, local persistence, camera screen, Sony/Fujifilm integration, AI/director, autofocus, zoom, Gemini, gallery/editor and capture/shutter behavior remain unchanged by this increment. The inherited backup baseline already integrates those hooks; this branch extends that work instead of replacing it.

## Remaining verification

No real Google grant, backend deployment or private photo upload occurred. Automated tests use local mock bytes and API fixtures. Owner browser/Google Picker configuration, actual folder permissions, Google upload/readback, iPhone 16 Pro Max camera performance, locked/background/5G behavior, AltStore persistence and Windows synchronization require the setup and physical-device checklist. Force-quitting can stop background transfers until reopening. Server administrators can access originals; encrypted host storage/backups are required and this is not end-to-end encryption against the owner/backend.

Official references: [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth), [Google Picker web integration](https://developers.google.com/workspace/drive/picker/guides/web-picker), [folder selection](https://developers.google.com/workspace/drive/picker/reference/picker.docsview.setselectfolderenabled), [Drive file parents/capabilities/checksums](https://developers.google.com/workspace/drive/api/reference/rest/v3/files), [resumable uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads), [server OAuth](https://developers.google.com/identity/protocols/oauth2/web-server), [Apple background transfers](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background), [Windows stream/mirror](https://support.google.com/drive/answer/13401938).
