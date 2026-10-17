# Focal owner-controlled photo backup: setup

Destination: **[Google Drive folder 1z7BpcVwsZAJ5ruPRHKbJ6VbnsQbOhrkU](https://drive.google.com/drive/folders/1z7BpcVwsZAJ5ruPRHKbJ6VbnsQbOhrkU)**. All uploaded resources are direct children of this folder. There is no new root or date hierarchy. A sharing link is not an upload credential.

This feature branch contains code, mock tests and deployment files. It does **not** provision a server, authorize a Google account, or enable uploads by default. No real user photographs were uploaded during implementation. Follow the fixture test step before authorizing real data.

The owner authorizes Google Drive on an always-on HTTPS backend. Test phones receive individual upload-only credentials through expiring invitations. Friends need neither Google accounts nor the owner's credentials. The iPhone never connects directly to the Windows PC. The backend and Drive can accept photos while that PC is switched off.

## 1. Run the mock tests

From the repository root, with Python 3.12 and Swift 5.9+:

```sh
python3 -m venv /tmp/focal-backup-tests
/tmp/focal-backup-tests/bin/pip install -r backup-server/requirements.txt
PYTHONPATH=backup-server /tmp/focal-backup-tests/bin/python -m unittest discover -s backup-server/tests -v
python3 scripts/test_backup_portable.py
python3 scripts/validate_backup.py
```

Linux needs OpenSSL development headers (`libssl-dev`) for the test harness's SHA-256 adapter. iOS production uses CryptoKit. Tests use temporary byte fixtures, simulated API responses and mock device grants. They never start a public server or contact Google. Allow local thread/event-loop operation in a restricted runner; this environment required its network sandbox allowance for Python ASGI thread callbacks even though all HTTP requests were in-process mocks.

## 2. Prepare the owner backend

Use a trusted Linux VPS/cloud host with Docker Engine + Compose, persistent disk, SSH access, automatic security updates, and enough free space. A domain you control must point to it. Open inbound TCP 80/443 for Caddy's HTTPS certificate issuance and service. Do **not** expose backend port 8000, the SQLite database, or `/data`. Keep the host online independently of the home PC. Running only on that PC would defeat offline-PC backup.

Clone this **private** repository on that host and check out `codex/focal-exact-drive-folder`. In `backup-server`:

```sh
cp .env.example .env
chmod 600 .env
```

Edit `.env` privately on the host:

| Variable | Set to |
|---|---|
| `BACKUP_DOMAIN` | Your DNS name, e.g. `backup.your-domain.example` |
| `PUBLIC_BASE_URL` | Exactly `https://` plus that name; no slash/path/port |
| `FOCAL_DATA` | `/data` inside the container |
| `OWNER_LABEL` | A label testers can recognize before enabling backup |
| `TOKEN_ENCRYPTION_KEY` | A newly generated Fernet key |
| `ADMIN_TOKEN` | A fresh random value, at least 32 bytes |
| `GOOGLE_CLIENT_ID` | The **Web application** OAuth client ID from step 3 |
| `GOOGLE_CLIENT_SECRET` | That web client's secret, backend only |
| `GOOGLE_PICKER_API_KEY` | Restricted browser key for the Google Picker API, from the same Google Cloud project |
| `GOOGLE_PROJECT_NUMBER` | Numeric project number from that project's dashboard, not its name or OAuth client ID |
| `STORAGE_BYTES_LIMIT` | Maximum unfinished server bytes, default 5 GiB |
| `DEVICE_DAILY_BYTES_LIMIT` | Per-device accepted bytes over 24 hours, default 2 GiB |

Generate the encryption key and admin token in a **private owner terminal**, not CI, an issue, or an app log. Use the installed test virtualenv above (or a local Python with cryptography):

```sh
/tmp/focal-backup-tests/bin/python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'
python3 -c 'import secrets; print(secrets.token_urlsafe(48))'
```

Copy each into the appropriate local `.env` entry. Do not commit `.env`, paste outputs into chat, or copy them into Codemagic. The encryption key must stay stable across restarts and upgrades. Back up it and the database securely and separately. Losing it prevents decrypting Google refresh tokens and resumable sessions. The master key does not encrypt image bytes: use encrypted host storage and encrypted backups for the entire data volume. Restrict host administrators; a compromised backend can access photos and its authorized Google files.

The Docker context excludes local secrets/data/tests, the app image runs as UID 10001, and Compose uses a read-only root with one persistent `focal-exact-folder-data` volume. Keep **one backend worker/replica**; the SQLite/filesystem design is for a personal owner service, not distributed replicas. Do not add access logging, exception dumps, request-body logging or tracing that includes OAuth callback queries, Authorization headers, invitations or filenames. Proxies/hosting dashboards must also redact/disable those logs.

## 3. Configure Google OAuth once, for the owner

1. In [Google Cloud Console](https://console.cloud.google.com/), create/select an owner-controlled project and enable **Google Drive API** and **Google Picker API**.
2. Configure the Google Auth Platform consent screen, application name, owner support email and audience. For personal testing, add **only your Google account** as an external test user. Friends are backend invitees, not Google OAuth users.
3. Add only `https://www.googleapis.com/auth/drive.file` to data access. No full-Drive scope, Gmail scope or Gemini API key is needed.
4. Create an OAuth client of type **Web application** for this server, with the exact authorized redirect URI:
   `https://YOUR_BACKUP_DOMAIN/admin/google/callback`
5. On the same Web client, register the JavaScript origin `https://YOUR_BACKUP_DOMAIN` (no path). Create a browser API key in the same project. Restrict it to **Google Picker API** and Websites `https://YOUR_BACKUP_DOMAIN/*` and `https://docs.google.com/*`, as required by Google's iframe-based Picker. This is a separate restricted Picker key, not a Gemini key and not an OAuth credential. Put it in `GOOGLE_PICKER_API_KEY`, and the numeric project number in `GOOGLE_PROJECT_NUMBER`.
6. Put its OAuth client ID and secret only in the backend `.env`. No iOS OAuth client, iOS URL scheme, client secret or Google refresh token belongs in the IPA.

Google's external **Testing** publishing status generally expires these Drive refresh tokens after seven days. Reauthorize the same owner at `/admin` when needed. For sustained use, configure an appropriate production consent state and follow Google's applicable verification/policy requirements. Do not assume personal/limited use bypasses policies. See [Google OAuth token expiry](https://developers.google.com/identity/protocols/oauth2#expiration) and [Web server authorization](https://developers.google.com/identity/protocols/oauth2/web-server).

Start the service:

```sh
docker compose up -d --build
```

Visit `https://YOUR_BACKUP_DOMAIN/health` and confirm `{"ok":true}` over valid HTTPS. A working health response establishes reachability only, not Google authorization. Open `https://YOUR_BACKUP_DOMAIN/admin` in the owner's normal browser. Enter the backend **admin token**, then complete Google's system/browser consent as the owner. Focal never asks for a Google password. The server uses authorization-code flow with S256 PKCE, an expiring one-use state and Secure/HttpOnly/SameSite browser cookie, then stores encrypted Google tokens. Verify:

```sh
docker compose exec backup python -m focal_backup.cli status
```

The OAuth callback opens an owner-only, ten-minute **Choose the exact folder** page. In Google's Picker, select the folder with ID **`1z7BpcVwsZAJ5ruPRHKbJ6VbnsQbOhrkU`**. Check the ID, not just its display name. The owner browser must be signed into the same Google account. That account must be able to add children to the folder. Other selections are rejected; the server independently reads the fixed folder ID and `capabilities.canAddChildren` using its encrypted owner grant. No test image is uploaded during authorization.

`drive.file` alone does not grant an existing folder by URL. The Picker grants the selected folder to this OAuth app. Google does not offer a literal folder-specific write-only OAuth scope: `drive.file` can read/edit app-authorized files. Focal's backend narrows its behavior to creating and verifying files in this one folder, and exposes only per-device upload/status APIs. It never exposes owner credentials or arbitrary Drive methods to testers. The short-lived access token needed by the official Picker is returned only to the authenticated owner's browser, with no-store responses; the refresh token and OAuth secret stay on the server.

Verify actual access from the owner terminal:

```sh
docker compose exec backup python -m focal_backup.cli verify-folder
docker compose exec backup python -m focal_backup.cli status
```

`folder_status` must be `verified`, and `target_folder_id` must exactly match the ID above. `drive_connected` alone reports OAuth status, not a successful upload. A verified test-card capture later establishes upload success. Every resumable upload supplies `parents: ["1z7BpcVwsZAJ5ruPRHKbJ6VbnsQbOhrkU"]`; the completion read verifies that parent, Drive file ID, original size and checksum. Date and capture association are private file metadata and sidecars, not new subfolders. Missing/trashed/read-only folder access pauses uploads with a recoverable owner error; there is no fallback to My Drive root or another folder.

**Existing backup deployments:** this branch uses a separate `focal-exact-folder-data` volume and refuses a legacy database or a database bound to another folder. Do not rename/reuse the old `focal-data` volume, delete it, or edit its binding by hand. Its receipts and resumable sessions refer to a different destination. Keep the old deployment/volume available for old pending photos; deploy this branch with fresh storage, preferably a separate HTTPS origin, then explicitly enroll phones with new invitations for future captures. Old enrollments stay bound to their original destination; they are not silently migrated or duplicated. No previous Drive files are moved or deleted. Keep the same new volume and encryption key for all subsequent exact-folder service upgrades.

Do not change the Google OAuth project/client casually: per-file authorization and private properties are client-bound. If the owner setup page expires or Picker access is denied, reopen `/admin` and authorize the **same owner**, then select the exact folder again. Never broaden the scope to full Drive just to bypass a missing folder grant.

## 4. Enroll each iPhone, including friends' devices

Create an invitation in the private owner SSH terminal:

```sh
docker compose exec backup python -m focal_backup.cli invite --label "My iPhone 16 Pro Max"
```

Share the code privately with that tester, along with the HTTPS server URL. The code is single-use and expires after 600 seconds by default (`--expires` supports 60–3600 seconds). Never use one shared permanent device secret.

On the phone, open **Focal → Settings → Photo Backup**. Enter the HTTPS URL and invitation, then tap **Authorize this device**. Check the displayed owner destination. Read the sharing notice, then enable **Automatic photo backup**. Connection alone does not enroll captures: the explicit toggle is off by default. After enabling, **all new real iPhone captures and their associated resources** from that device are shared with the owner silently. Obtain each friend's informed agreement before enabling this behavior. They can disable or disconnect in Settings without needing Google credentials.

First test with a nonprivate photograph of a test card. The camera screen has no new upload indicator, toast, animation or sound. Inspect pending/failed counts and last success in Settings; separately verify the real file in Drive and its format/size/hash. Do not interpret a successful server transfer as Drive completion.

Old photos, demo photos and Sony postview/capture events are not retroactively enrolled. For this first implementation, Sony photos are excluded because the existing adapter does not prove that a locally received file is the full original. Sony connection/live view/shutter/settings are unchanged.

A capture date is fixed in the phone's local calendar when saved; changing time zone later does not move it. All resources use stable `capture UUID + role` identities. Typical filenames are already safe UUID names. A name collision adds a stable resource-hash suffix, never overwriting another file. DNG/RAW and HEIC/JPEG bytes are sent unchanged; scan/wide-preview derivatives retain their own explicit roles and a `.focal.json` sidecar records the capture association.

## 5. Recover, revoke and maintain

Inspect connection IDs and safe counts:

```sh
docker compose exec backup python -m focal_backup.cli status
```

If a phone loses its Keychain credential or is re-signed to a different Keychain identity, issue a **recovery invitation for the original device ID**, not a new grant:

```sh
docker compose exec backup python -m focal_backup.cli invite --label "Recovered phone" --recover-device ORIGINAL_DEVICE_ID
```

Disconnect/reconnect that phone with the recovery code, enable backup, then tap Retry now. A recovery invitation rotates the old token and keeps the same destination/device identity. Lost invitation responses require another recovery invitation; codes cannot be redeemed twice. A new device ID, server URL or owner destination cannot inherit old photo enrollment. Existing pending work remains paused for the original identity; never silently reassign it.

Revoke a lost or untrusted device:

```sh
docker compose exec backup python -m focal_backup.cli revoke-device DEVICE_ID
```

This blocks new device requests and new worker claims. A transfer already accepted or an in-flight Drive chunk can still complete. Revocation does not erase Google files. Invite recovery explicitly to reinstate an authorized device.

After fixing Google storage/quota or reauthorizing the same owner, resume worker retries:

```sh
docker compose exec backup python -m focal_backup.cli retry-drive
```

For explicit withdrawal of unfinished **server staging**, revoke the device, stop the backend worker, and run an isolated maintenance command:

```sh
docker compose stop backup
docker compose run --rm backup python -m focal_backup.cli discard-pending DEVICE_ID --confirm-delete-server-staging
docker compose up -d backup
```

The phone's originals and any existing Drive files remain. A later explicitly recovered phone can upload again; Google private resource markers/pre-generated IDs prevent duplicate completed files. Keep normal backups rather than deleting the volume. To bound long-lived completion receipts, `prune-completed --older-than-days 365` deletes only old verified server records; it does not delete Drive files. A stale client may need to resend its original before the worker can verify a pruned receipt against Drive.

Server safety limits are 5 GiB unfinished bytes (configurable), 2 GiB per device/day (configurable), 512 MiB/resource, 1000 unfinished resources and 100,000 receipts. iPhone limits are 4 MiB/transfer, 64 MiB staging, 256 MiB free-space reserve, 5000 unfinished resources, 20,000 queue records, 32 MiB manifest. Queue/storage failures remain visible and recoverable in Settings; originals are never automatically removed. Failed work is not retried in a hot loop. A fresh network opportunity automatically requeues offline failures with a bounded retry budget; it never clears a revoked grant or integrity/quota error. Rate-limited work stays durably deferred with bounded counters/delays rather than failing after one retry burst; server Google rate limits also honor Retry-After. iOS must provide an execution window to retry device work. For other terminal failures, tap Retry now after resolving the cause. To free a fully populated phone queue, first confirm Drive originals and then manually remove the corresponding backed-up photos in Focal. No automatic local deletion or hidden unlimited staging is implemented.

Deleting in Focal removes pending local work and local images. It does **not** retract bytes already accepted by the backend or erase cloud copies. Disconnecting/pausing cancels pending device transfers; accepted backend work can finish. Use the owner maintenance command/Drive UI for explicit cloud-side retention decisions. Keep the data volume and master key through container upgrades. Reauthorizing a different Google owner on the same backend destination is rejected; deploy a fresh destination and explicitly enroll devices instead.

## 6. Windows PC synchronization

Install [Google Drive for desktop](https://www.google.com/drive/download/) on Windows and sign in **as the owner**, not with a tester device grant. Open the exact folder link above and identify its actual display name and location in your own Drive. No folder called `Focal Photos` is created. Confirm a verified test capture appears directly inside that existing folder.

Choose one strategy:

- **Mirror My Drive:** Drive for desktop Settings → Preferences → Google Drive → Mirror files. Choose the local folder (with sufficient disk space). My Drive files are downloaded to normal disk storage; this mirrors the whole My Drive selection supported by the client, not just Focal's folder.
- **Stream + offline folder:** Keep streaming, open My Drive in File Explorer, right-click **the existing target folder** → Offline access → **Available offline**. Wait for synchronization/offline-completion indicators. A streamed shortcut or visible filename alone does not prove bytes are on disk. Streamed offline files depend on Drive for desktop running and its virtual-drive/cache behavior; use mirroring for a conventional durable local folder.

Drive letters and paths depend on your setup; do not assume `G:`. In either strategy, the PC may be off when the phone captures/uploads. Once the PC is on, online and signed into Drive for desktop, it synchronizes. Leave it running until transfers complete. The phone needs internet to the backend, not the PC's IP address. No custom Windows receiver/server is needed.

See Google's [streaming versus mirroring guide](https://support.google.com/drive/answer/13401938) and [offline access guidance](https://support.google.com/drive/answer/13470231).

## 7. Codemagic / AltStore

Build branch `codex/focal-exact-drive-folder`, version **2.12.1 (40)**, using existing Codemagic **ios-sideload**. Its simulator tests precede the unsigned device archive/IPA. AltStore performs personal signing as before; no paid background entitlement, app group, Google SDK or iOS Google sign-in client is added. Keep the same signing identity/bundle where practical to preserve the app container and Keychain; uninstalling can remove originals and queue.

Do not add backend secrets/device invitation codes/Google tokens to Codemagic. The backend is configured through Settings and owner SSH. Existing private Gemini Debug-build tooling and its secret group are independent; do not add the backend's credentials to them. Normal Release builds do not embed the optional Gemini local configuration.

The dedicated GitHub Actions **Focal owner photo backup validation** workflow runs portable regressions, backend tests, Docker build, native simulator XCTest and an unsigned Release iPhone archive on this feature branch. The earlier backup baseline passed [CI run 39034539352](https://github.com/r3hal/focal-private/actions/runs/39034539352). See [the validation record](VALIDATION.md) for this exact-folder branch's results. This does not validate a deployed backend or physical iPhone background behavior. CI is secret-free and uses only fixture data.

## 8. Physical-device acceptance checklist

Record version/build, iOS version, transport and timestamps in a private test log. Do not post images, credentials or sensitive filenames.

1. With backup off, capture JPEG/HEIC and RAW; prove local capture/gallery/editor/paired save work and no network file enrollment occurs.
2. Enroll and enable, capture a test card, verify processed + original + DNG + scan/wide-preview where present and `.focal.json` association. Compare byte size and SHA-256 to originals. Confirm each Drive file has the exact target folder as its parent and Windows receives the same bytes after turning on the PC.
3. Capture offline; terminate/relaunch normally and reboot; unlock once and restore internet. Verify recovery with no duplicate Drive files.
4. Test Wi-Fi and cellular/5G, large RAW chunks, transient packet loss, backend restart mid-upload, lost chunk acknowledgements, owner quota full and Google refresh expiry/revocation. Verify local originals survive.
5. Lock/background the phone mid-upload. Check iOS background delegates and completion persistence. **Force-quitting cancels/prevents automatic transfers until reopening; immediate upload is not guaranteed.** iOS can suspend retry/receipt polling until another permitted execution window or launch.
6. Disable/disconnect while a transfer is active; verify no new device transfers/enrollment and understand previously accepted server work may finish. Revoke/recover the same grant, switch owner/server, and ensure old queues are never rerouted.
7. Compare shutter latency, preview FPS, AI/AF/automatic zoom, film effects and paired save with backup off/on, including a burst and 5G RAW. No measured no-latency-regression claim is made without this test.
8. Confirm Sony Wi-Fi/live view/ISO/remote shutter and Gemini scan remain independent. A Sony Wi-Fi network without internet may delay backup until routing/internet is available; Focal must not leave that network or interfere with Sony.
9. Confirm the camera has no per-photo backup UI, notification or automatic shutter. Check low-storage/queue-full recovery in Settings.

Native simulator tests cannot establish cellular radio behavior, iOS background scheduling, AltStore Keychain persistence or camera performance. These checks require real hardware and the deployed, owner-authorized backend.
