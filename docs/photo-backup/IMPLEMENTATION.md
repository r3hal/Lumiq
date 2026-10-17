# Owner-controlled photo backup implementation

Feature branch: `codex/focal-google-drive-backup`; version 2.12.0 (39). Base: existing Gemini test branch at `178c001fa891614024e609c2fc1d548be6825e9a`. Main and the Gemini branch are not merged or updated by this work. See [setup, maintenance, Windows and device checks](SETUP.md) and [recorded validation](VALIDATION.md).

## Architecture and audited integration

The existing `PhotoLibrary.add` writes each local camera resource on its existing detached task, then atomically persists `library.json`, then publishes the new photo. Optional Photos-library export is separate. The new hook executes **after that local manifest commit**. It does no hashing, network calls, staging or queue I/O on the shutter/save path. Before the commit, a small immutable backup enrollment marker is included in the same photo entry, so a crash between local commit and queue insertion can be recovered at launch. Legacy/demo/Sony entries without a supported enrollment are not scanned into uploads.

A utility actor hashes the original files, persists a JSON queue atomically, stages one bounded file chunk, then creates a real background `URLSession` upload. Queue states are queued → preparing → uploading → verifying → complete, with delayed retry and explicit failed states. `verifying` means the owner server has accepted the bytes; it is not a successful Google backup. Completion requires the server's verified Drive file ID, full size and the exact queued SHA-256. The server independently hashes received bytes, verifies Drive's SHA-256 (or MD5 plus size when SHA-256 is absent), and only then issues a completed receipt. Strong-checksum disagreement cannot be masked by a matching weaker checksum.

Capture UUID + resource role gives each resource a stable ID. The local capture manifest retains owner destination, device grant ID and exact HTTPS server; switching any of those pauses old work. No new destination can inherit old captures without the original owner/device recovery. Credentials are not present in that manifest, the queue or sidecar. The iOS Keychain holds a per-device, non-synchronizing upload-only bearer token with AfterFirstUnlockThisDeviceOnly protection. URLSession may persist its own protected request headers as part of system-managed background tasks; these are not app logs or an embedded shared credential.

One background session and actor-owned transfer generation reject stale callbacks, adopt existing tasks after relaunch and cancel unexpected tasks. Upload chunks are file-backed, at most 4 MiB, and allow cellular/expensive/constrained connections. Metadata HTTP is bounded, ephemeral, cookie/cache-free and refuses redirects. Offset conflicts probe authoritative server state before resending. Consecutive failures use eight bounded attempts, exponential delay and Retry-After; successful chunks do not consume the retry budget. Original files are never deleted by backup. Chunk staging is cleaned after durable acknowledgement; sidecar/staging cleanup does not remove the gallery original.

The owner backend uses FastAPI, SQLite WAL/FULL commits and private bounded staging. An expiring one-use invitation creates a revocable device token; only its SHA-256 is stored. Device endpoints can reserve/append/read the status of their own uploads. They cannot download photos, list another device's work, read Google tokens, pick a different Drive account or make arbitrary Drive requests. HTTPS, host/origin checks, bounded bodies, per-device/IP rate limits, file/receipt/storage budgets and same-destination checks are enforced. File data is fsynced before offset acknowledgement. An independent single worker survives phone/PC absence and retries Google uploads from persistent server files.

Google authorization happens only on the owner server through the owner's browser: Web OAuth authorization code + S256 PKCE, one-use state/cookie, offline refresh and `drive.file`. Google tokens, PKCE verifiers and Google resumable URLs are encrypted with Fernet using an external master key. Google requests use fixed HTTPS origins and never follow redirects. The same owner must reauthorize an expired grant; a different Google account cannot replace the existing destination. Device invitations/credentials, server admin credentials, Google OAuth and Gemini API credentials have separate roles.

The worker creates app-owned date folders, reserves Drive IDs before creation, and persists resumable session state. Stable IDs and private app properties cover lost acknowledgements, restarts and older DB restores. An unrelated same-name file is never overwritten; collisions receive a deterministic suffix. Transfer uses binary media uploads, not image conversion. API errors are reduced to safe codes; no content, sensitive filenames, Google tokens or callback queries are intentionally logged. Deployment instructions also require proxy/host log redaction and encrypted persistent storage. The server sees originals: this is not end-to-end encryption against the owner/server administrator.

## Existing features preserved

No source in the camera controls/controller, AI/director, autofocus, Sony, Gemini service, editor or precision-control directories changed. Seventy exact SHA-256 source guards enforce that preservation in `scripts/validate_backup.py`; production portable framing/Gemini and Sony regressions also run. Existing Photos export, RAW creation, paired capture, user-only shutter, AltStore signing and Codemagic workflows remain in place. No extra camera control or per-photo upload notification was introduced. The only added visible UI is Settings authorization/enablement/status/recovery and updated privacy text.

The root app attaches the coordinator to the library and forwards lifecycle/background URLSession events. App-private library behavior stays primary. No Photos read permission, background audio/fetch mode, paid entitlement, Google mobile SDK, native Google account flow or Windows custom receiver was added. The privacy manifest adds disk-space access reason E174.1 for locally observable low-storage behavior and the app-scoped device ID used for backup; free-space measurements are not uploaded.

## Limits requiring explicit acknowledgement

- Linux compilation/tests cover the real Foundation queue/protocol code but do not build the iOS app. Native UIKit/SwiftUI/Keychain/background delegate checks need Xcode CI and physical validation.
- Background URLSession is OS-scheduled. Force-quit stops automatic transfers until reopening; retry timers/receipt polls cannot run continuously while suspended. Starting/succeeding an API call is not proof of physical background delivery.
- An enabled device shares new original captures with this owner without per-photo confirmation. Settings explains this before the tester enables it. Pausing stops new enrollment/device transfers, not already accepted backend work. Local deletion does not retract cloud copies.
- Server caps, iPhone caps, Google quota and mobile data charges apply. There is no claim of unlimited queue/storage or measured zero shutter/preview impact; utility work and bounded chunks reduce interference, but the real-device checklist is required.
- Sony is deliberately not enrolled until the app proves an original file has been acquired locally. A remote shutter/live-view JPEG is not such proof. No Sony code changed.
- No backend has been deployed or real Google owner authorized by this implementation. All automated inputs are fixtures. Google production consent/client configuration and physical Windows/iPhone acceptance remain owner setup tasks.

## Exact changed files

New app files:

- `Focal/Backup/BackupModels.swift`
- `Focal/Backup/BackupDiskStore.swift`
- `Focal/Backup/BackupNetworking.swift`
- `Focal/Backup/BackupEngine.swift`
- `Focal/Backup/BackupBackgroundSession.swift`
- `Focal/Backup/BackupKeychain.swift`
- `Focal/Backup/PhotoBackupCoordinator.swift`
- `Focal/Backup/PhotoBackupSettingsView.swift`

Existing app/project files:

- `Focal/Library/PhotoLibrary.swift` — optional persisted enrollment and post-commit handoff only.
- `Focal/App/FocalApp.swift` — coordinator attachment, lifecycle and background delegate.
- `Focal/App/SettingsView.swift` — dedicated backup section and privacy explanation.
- `Focal/Resources/PrivacyInfo.xcprivacy` — disk-space reason/device identifier.
- `Focal.xcodeproj/project.pbxproj` — generated registration/version 2.12.0 (39).
- `scripts/generate_project.py` — version/privacy entries; existing source discovery reused.
- `scripts/validate_structure.py` — register added tests, preserve prior guards.
- `.gitignore` — exclude server-local secrets/data/virtualenv.

Tests/validation:

- `FocalTests/PhotoBackupTests.swift`
- `FocalTests/PhotoBackupPersistenceTests.swift`
- `scripts/test_backup_portable.py`
- `scripts/validate_backup.py`
- `.github/workflows/photo-backup-validation.yml`
- `docs/PHOTO-BACKUP-PRESERVED-SOURCES.json`

Backend/deployment:

- `backup-server/focal_backup/__init__.py`
- `backup-server/focal_backup/store.py`
- `backup-server/focal_backup/google_drive.py`
- `backup-server/focal_backup/app.py`
- `backup-server/focal_backup/cli.py`
- `backup-server/tests/test_backup.py`
- `backup-server/requirements.txt`
- `backup-server/Dockerfile`
- `backup-server/compose.yaml`
- `backup-server/Caddyfile`
- `backup-server/.env.example`
- `backup-server/.dockerignore`

Documentation:

- `docs/photo-backup/SETUP.md`
- `docs/photo-backup/IMPLEMENTATION.md`
- `docs/photo-backup/VALIDATION.md`

## Documentation used

- [Google server OAuth](https://developers.google.com/identity/protocols/oauth2/web-server) and [token expiry](https://developers.google.com/identity/protocols/oauth2#expiration).
- [Drive minimal per-file scope](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).
- [Drive resumable uploads and pre-generated IDs](https://developers.google.com/workspace/drive/api/guides/manage-uploads).
- [Drive file size/checksum metadata](https://developers.google.com/workspace/drive/api/reference/rest/v3/files).
- [Apple background file transfers](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).
- [Apple required-reason privacy APIs](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
- [Google Drive Desktop stream/mirror](https://support.google.com/drive/answer/13401938).
