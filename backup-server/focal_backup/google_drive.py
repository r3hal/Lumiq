from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import secrets
import time
from urllib.parse import urlencode, urlparse

from cryptography.fernet import Fernet, InvalidToken
import httpx

from .store import Store, Problem, digest, TARGET_FOLDER_ID

DRIVE_SCOPE = "https://www.googleapis.com/auth/drive.file"
FOLDER_MIME = "application/vnd.google-apps.folder"


class GoogleFailure(Exception):
    def __init__(self, code: str, retry_after: float = 0):
        super().__init__(code)
        self.code, self.retry_after = code, min(86400, max(0, retry_after))


class GoogleHTTP:
    """Fixed Google origins, bounded metadata, no cookies/redirects or logging."""
    async def send(self, method, url, *, token=None, form=None, body=None, data=None, headers=None):
        parsed = urlparse(url)
        valid = (parsed.scheme == "https" and not parsed.username and not parsed.password and not parsed.fragment
                 and parsed.port in (None, 443)
                 and ((parsed.hostname == "www.googleapis.com" and
                       (parsed.path.startswith("/drive/v3/") or parsed.path == "/upload/drive/v3/files"))
                      or (parsed.hostname == "oauth2.googleapis.com" and parsed.path in ("/token", "/revoke"))))
        if not valid:
            raise GoogleFailure("invalid_google_endpoint")
        headers = dict(headers or {})
        if token:
            headers["Authorization"] = "Bearer " + token
        try:
            async with httpx.AsyncClient(timeout=60, follow_redirects=False) as client:
                async with client.stream(method, url, headers=headers, data=form, json=body, content=data) as response:
                    chunks, length = [], 0
                    async for chunk in response.aiter_bytes():
                        length += len(chunk)
                        if length > 131072:
                            raise GoogleFailure("invalid_google_response")
                        chunks.append(chunk)
                    raw = b"".join(chunks)
                    try:
                        value = json.loads(raw) if raw else {}
                    except (ValueError, UnicodeDecodeError):
                        value = {}
                    return response.status_code, dict(response.headers), value
        except (httpx.HTTPError, OSError):
            raise GoogleFailure("google_temporary") from None


class OwnerGoogleAuthorization:
    def __init__(self, store: Store, http=None):
        self.store, self.http = store, http or GoogleHTTP()
        try:
            self.cipher = Fernet(store.settings.encryption_key.encode())
        except (ValueError, TypeError):
            raise RuntimeError("TOKEN_ENCRYPTION_KEY must be a valid Fernet key") from None
        self.lock = asyncio.Lock()

    def encrypt(self, value):
        return self.cipher.encrypt(json.dumps(value, separators=(",", ":")).encode()).decode()

    def decrypt(self, value):
        try:
            return json.loads(self.cipher.decrypt(value.encode()))
        except (InvalidToken, ValueError, TypeError, AttributeError):
            raise GoogleFailure("owner_authorization") from None

    @property
    def connected(self):
        return bool(self.store.get("google_tokens")) and self.store.get("google_status") == "active"

    def begin(self):
        settings = self.store.settings
        if not settings.google_client_id or not settings.google_client_secret:
            raise Problem("oauth_not_configured", 503)
        verifier, state, cookie = secrets.token_urlsafe(64), secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        with self.store.transaction() as db:
            db.execute("DELETE FROM oauth_states WHERE expires<?", (time.time(),))
            db.execute("INSERT INTO oauth_states VALUES(?,?,?,?)",
                       (digest(state), digest(cookie), self.encrypt(verifier), time.time() + 600))
        params = {"client_id": settings.google_client_id, "redirect_uri": settings.public_url + "/admin/google/callback",
                  "response_type": "code", "scope": DRIVE_SCOPE, "access_type": "offline", "prompt": "consent",
                  "state": state, "code_challenge": challenge, "code_challenge_method": "S256"}
        return "https://accounts.google.com/o/oauth2/v2/auth?" + urlencode(params), cookie

    async def complete(self, code, state, cookie):
        if not code or len(code) > 4096 or not state or not cookie:
            raise Problem("invalid_oauth_state", 400)
        with self.store.transaction() as db:
            row = db.execute("SELECT * FROM oauth_states WHERE hash=?", (digest(state),)).fetchone()
            if not row or row["expires"] < time.time() or not secrets.compare_digest(row["cookie_hash"], digest(cookie)):
                raise Problem("invalid_oauth_state", 400)
            db.execute("DELETE FROM oauth_states WHERE hash=?", (digest(state),))  # One-use state, before network.
        verifier = self.decrypt(row["verifier"])
        settings = self.store.settings
        async with self.lock:
            status, _, tokens = await self.http.send("POST", "https://oauth2.googleapis.com/token", form={
                "client_id": settings.google_client_id, "client_secret": settings.google_client_secret,
                "code": code, "code_verifier": verifier, "grant_type": "authorization_code",
                "redirect_uri": settings.public_url + "/admin/google/callback"})
            if status != 200 or not tokens.get("access_token") or not tokens.get("refresh_token"):
                raise GoogleFailure("owner_authorization")
            if DRIVE_SCOPE not in tokens.get("scope", "").split():
                raise GoogleFailure("owner_authorization")
            status, _, about = await self.http.send("GET", "https://www.googleapis.com/drive/v3/about?fields=user(permissionId)", token=tokens["access_token"])
            identity = about.get("user", {}).get("permissionId")
            if status != 200 or not isinstance(identity, str) or not identity:
                raise GoogleFailure("owner_authorization")
            owner_hash = digest(identity)
            tokens["expires_at"] = time.time() + min(7200, max(60, int(tokens.get("expires_in", 3600))))
            with self.store.transaction() as db:
                previous = db.execute("SELECT value FROM config WHERE key='google_owner'").fetchone()
                if previous and not secrets.compare_digest(previous[0], owner_hash):
                    # Never redirect old device queues to another Google account.
                    raise Problem("different_google_owner", 409)
                for key, value in {"google_owner": owner_hash, "google_tokens": self.encrypt(tokens), "google_status": "active"}.items():
                    db.execute("INSERT INTO config VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))
                db.execute("INSERT INTO config VALUES('folder_status','needs_selection') ON CONFLICT(key) DO UPDATE SET value=excluded.value")

    async def access_token(self, force=False):
        async with self.lock:
            if not self.connected:
                raise GoogleFailure("owner_authorization")
            tokens = self.decrypt(self.store.get("google_tokens"))
            if not force and tokens.get("expires_at", 0) > time.time() + 120:
                return tokens["access_token"]
            settings = self.store.settings
            status, _, fresh = await self.http.send("POST", "https://oauth2.googleapis.com/token", form={
                "client_id": settings.google_client_id, "client_secret": settings.google_client_secret,
                "refresh_token": tokens["refresh_token"], "grant_type": "refresh_token"})
            if status == 400 or status == 401:
                self.store.set("google_status", "needs_authorization")
                raise GoogleFailure("owner_authorization")
            if status != 200 or not fresh.get("access_token"):
                raise GoogleFailure("google_temporary")
            tokens.update(fresh)
            tokens["expires_at"] = time.time() + min(7200, max(60, int(fresh.get("expires_in", 3600))))
            self.store.set("google_tokens", self.encrypt(tokens))
            return tokens["access_token"]

    async def revoke(self):
        saved = self.store.get("google_tokens")
        if saved:
            tokens = self.decrypt(saved)
            status, _, _ = await self.http.send("POST", "https://oauth2.googleapis.com/revoke", form={"token": tokens["refresh_token"]})
            if status != 200:
                raise GoogleFailure("google_temporary")
        self.store.set("google_status", "needs_authorization")
        self.store.set("google_tokens", "")


class GoogleDrive:
    def __init__(self, authorization: OwnerGoogleAuthorization):
        self.auth, self.store, self.http = authorization, authorization.store, authorization.http

    async def request(self, method, path, *, body=None, data=None, headers=None, allow=(200,)):
        token = await self.auth.access_token()
        url = path if path.startswith("https://") else "https://www.googleapis.com/drive/v3/" + path
        status, response_headers, result = await self.http.send(method, url, token=token, body=body, data=data, headers=headers)
        if status == 401:
            token = await self.auth.access_token(force=True)
            status, response_headers, result = await self.http.send(method, url, token=token, body=body, data=data, headers=headers)
        if status == 401:
            self.store.set("google_status", "needs_authorization")
            raise GoogleFailure("owner_authorization")
        if status not in allow:
            reasons = [item.get("reason") for item in result.get("error", {}).get("errors", [])] if isinstance(result.get("error"), dict) else []
            if "storageQuotaExceeded" in reasons:
                raise GoogleFailure("drive_quota")
            limited = status == 429 or any(r in reasons for r in ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded"])
            if limited or status >= 500:
                try:
                    retry = float(response_headers.get("retry-after", 0))
                except (ValueError, TypeError):
                    retry = 0
                raise GoogleFailure("google_rate_limited" if limited else "google_temporary", retry)
            raise GoogleFailure("drive_permission" if status == 403 else "invalid_google_response")
        return status, response_headers, result

    async def generate_id(self):
        _, _, result = await self.request("GET", "files/generateIds?count=1&space=drive&type=files")
        values = result.get("ids", [])
        if len(values) != 1 or not isinstance(values[0], str):
            raise GoogleFailure("invalid_google_response")
        return values[0]

    async def metadata(self, file_id):
        from urllib.parse import quote
        status, _, result = await self.request("GET", "files/" + quote(file_id, safe="") + "?supportsAllDrives=true&fields=id,size,sha256Checksum,md5Checksum,appProperties,trashed,mimeType,parents", allow=(200, 404))
        if status == 200 and result.get("id") != file_id:
            raise GoogleFailure("invalid_google_response")
        return result if status == 200 else None

    @staticmethod
    def q(value):
        return value.replace("\\", "\\\\").replace("'", "\\'")

    async def find(self, query):
        _, _, result = await self.request("GET", "files?" + urlencode({"q": query, "spaces": "drive", "pageSize": 100,
            "supportsAllDrives": "true", "includeItemsFromAllDrives": "true",
            "fields": "files(id,name,appProperties),nextPageToken"}))
        if result.get("nextPageToken"):
            raise GoogleFailure("ambiguous_folder")
        return result.get("files", [])

    async def verify_target_folder(self, *, owner_selection=False):
        if not owner_selection and self.store.get("folder_status") not in ("verified", "unavailable"):
            raise GoogleFailure("folder_authorization")
        try:
            status, _, folder = await self.request("GET", "files/" + TARGET_FOLDER_ID +
                "?supportsAllDrives=true&fields=id,mimeType,trashed,capabilities(canAddChildren)", allow=(200, 404))
            if (status != 200 or folder.get("id") != TARGET_FOLDER_ID or folder.get("trashed")
                    or folder.get("mimeType") != FOLDER_MIME
                    or folder.get("capabilities", {}).get("canAddChildren") is not True):
                self.store.set("folder_status", "unavailable")
                raise GoogleFailure("folder_authorization")
        except GoogleFailure as error:
            if error.code in ("owner_authorization", "drive_permission"):
                self.store.set("folder_status", "unavailable")
            if error.code == "drive_permission":
                raise GoogleFailure("folder_authorization") from None
            raise
        if self.store.get("folder_status") != "verified":
            self.store.set("folder_status", "verified")
        return TARGET_FOLDER_ID

    def verified(self, metadata, row, md5=None):
        if (not metadata or not metadata.get("id") or metadata.get("trashed")
                or metadata.get("parents") != [TARGET_FOLDER_ID]
                or str(metadata.get("size")) != str(row["size"])):
            return False
        props = metadata.get("appProperties", {})
        if props.get("focalResource") != row["key"] or props.get("focalDestination") != self.store.destination:
            return False
        if metadata.get("sha256Checksum"):
            return metadata["sha256Checksum"] == row["sha256"]
        return md5 is not None and metadata.get("md5Checksum") == md5

    async def upload(self, row):
        path = self.store.files / (row["key"] + ".bin")
        if not path.is_file():
            raise GoogleFailure("missing_original")
        with path.open("rb") as source:
            sha = hashlib.file_digest(source, "sha256").hexdigest()
        if path.stat().st_size != row["size"] or sha != row["sha256"]:
            raise GoogleFailure("integrity")
        with path.open("rb") as source:
            md5 = hashlib.file_digest(source, "md5").hexdigest()
        folder = await self.verify_target_folder()
        if row["drive_id"]:
            current = await self.metadata(row["drive_id"])
            if current:
                if not self.verified(current, row, md5):
                    raise GoogleFailure("integrity")
                return row["drive_id"]
        # Private appProperties remain a fallback after a restored older DB.
        found = await self.find("trashed=false and appProperties has { key='focalResource' and value='" + row["key"] + "' }")
        if len(found) > 1:
            raise GoogleFailure("integrity")
        for candidate in found:
            current = await self.metadata(candidate["id"])
            if self.verified(current, row, md5):
                return candidate["id"]
            # Never silently duplicate/move an existing capture that was moved
            # out of the destination or whose integrity can no longer be proven.
            raise GoogleFailure("folder_changed")
        if not row["drive_id"]:
            row["drive_id"] = await self.generate_id()
            self.store.update_resource(row["key"], drive_id=row["drive_id"])
        if not row["drive_name"]:
            names = await self.find("trashed=false and '" + self.q(folder) + "' in parents and name='" + self.q(row["filename"]) + "'")
            name = row["filename"]
            if names:
                stem, dot, ext = name.rpartition(".")
                name = (stem if dot else name) + "--" + row["key"][:10] + (("." + ext) if dot else "")
            row["drive_name"] = name
            self.store.update_resource(row["key"], drive_name=name)
        session = self.auth.decrypt(row["session"]) if row["session"] else None
        offset = 0
        if session:
            status, headers, _ = await self.request("PUT", session, data=b"", headers={"Content-Length": "0", "Content-Range": "bytes */" + str(row["size"])}, allow=(200, 201, 308, 404))
            if status in (200, 201):
                current = await self.metadata(row["drive_id"])
                if not self.verified(current, row, md5):
                    raise GoogleFailure("integrity")
                return row["drive_id"]
            if status == 404:
                session = None
            else:
                offset = self.offset(headers.get("range"), row["size"])
        if not session:
            body = {"id": row["drive_id"], "name": row["drive_name"], "mimeType": row["mime"], "parents": [folder],
                    "appProperties": {"focalResource": row["key"], "focalDestination": self.store.destination, "focalCapture": row["capture_id"], "focalDate": row["day"], "focalRole": row["role"]}}
            status, headers, _ = await self.request("POST", "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true&fields=id,parents,size,sha256Checksum,md5Checksum,appProperties", body=body,
                headers={"X-Upload-Content-Type": row["mime"], "X-Upload-Content-Length": str(row["size"])}, allow=(200, 201, 409))
            if status == 409:
                current = await self.metadata(row["drive_id"])
                if self.verified(current, row, md5):
                    return row["drive_id"]
                raise GoogleFailure("integrity")
            session = headers.get("location", "")
            p = urlparse(session)
            if p.scheme != "https" or p.hostname != "www.googleapis.com" or p.path != "/upload/drive/v3/files" or p.username or p.fragment or p.port not in (None, 443):
                raise GoogleFailure("invalid_google_response")
            self.store.update_resource(row["key"], session=self.auth.encrypt(session))
        with path.open("rb") as source:
            source.seek(offset)
            while offset < row["size"]:
                # Re-check revocation between chunks; never transfer a new resource for a revoked device.
                with self.store.transaction() as db:
                    active = db.execute("SELECT revoked FROM devices WHERE id=?", (row["device_id"],)).fetchone()
                if not active or active[0]:
                    raise GoogleFailure("device_revoked")
                data = source.read(min(4 * 1024**2, row["size"] - offset))
                if not data:
                    raise GoogleFailure("integrity")
                status, headers, _ = await self.request("PUT", session, data=data,
                    headers={"Content-Type": row["mime"], "Content-Length": str(len(data)),
                             "Content-Range": f"bytes {offset}-{offset + len(data) - 1}/{row['size']}"}, allow=(200, 201, 308, 404))
                if status == 404:
                    self.store.update_resource(row["key"], session=None)
                    raise GoogleFailure("google_temporary")
                if status in (200, 201):
                    break
                new_offset = self.offset(headers.get("range"), row["size"])
                if new_offset <= offset:
                    raise GoogleFailure("google_temporary")
                offset = new_offset
                source.seek(offset)
                self.store.update_resource(row["key"], lease_until=time.time() + 300)
        current = await self.metadata(row["drive_id"])
        if not self.verified(current, row, md5):
            raise GoogleFailure("integrity")
        return row["drive_id"]

    @staticmethod
    def offset(value, total):
        if value is None:
            return 0
        if not value.startswith("bytes=0-"):
            raise GoogleFailure("invalid_google_response")
        try:
            result = int(value[8:]) + 1
        except ValueError:
            raise GoogleFailure("invalid_google_response") from None
        if not 0 < result <= total:
            raise GoogleFailure("invalid_google_response")
        return result


async def worker_once(store: Store, drive):
    row = store.claim()
    if not row:
        return False
    try:
        file_id = await drive.upload(row)
        # The adapter returns only after Drive ID, ownership marker, size and checksum checks.
        store.update_resource(row["key"], drive_id=file_id, state="complete", error=None, session=None, lease_until=0)
        (store.files / (row["key"] + ".bin")).unlink(missing_ok=True)
    except GoogleFailure as error:
        attempt = row["attempts"] + 1
        code = "folder_authorization" if error.code == "drive_permission" else error.code
        if code == "folder_authorization":
            store.set("folder_status", "unavailable")
        durable_deferral = code in ("owner_authorization", "drive_quota", "folder_authorization", "google_rate_limited")
        failed = code in ("integrity", "missing_original", "device_revoked", "folder_changed") or (attempt >= 8 and not durable_deferral)
        delay = max(min(21600, 30 * 2**min(10, attempt - 1)), error.retry_after)
        if durable_deferral:
            delay = max(delay, 300)
        store.update_resource(row["key"], state="failed" if failed else "pendingDrive", error=code,
                              attempts=min(attempt, 8), retry_at=time.time() + delay, lease_until=0)
    except OSError:
        store.update_resource(row["key"], state="failed", error="owner_storage", lease_until=0)
    except Exception:
        # Malformed upstream data must not leave an endlessly reclaimed lease.
        attempt = row["attempts"] + 1
        store.update_resource(row["key"], state="failed" if attempt >= 8 else "pendingDrive", error="invalid_google_response",
                              attempts=min(attempt, 8), retry_at=time.time() + min(21600, 30 * 2**min(10, attempt-1)), lease_until=0)
    return True
