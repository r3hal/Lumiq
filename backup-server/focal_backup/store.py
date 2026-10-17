from __future__ import annotations

import contextlib
import hashlib
import json
import os
from pathlib import Path
import secrets
import sqlite3
import time
import uuid
from dataclasses import dataclass
from urllib.parse import urlparse


class Problem(Exception):
    def __init__(self, code: str, status: int = 400):
        super().__init__(code)
        self.code, self.status = code, status


@dataclass(frozen=True)
class Settings:
    data: Path
    public_url: str
    encryption_key: str
    admin_token: str
    google_client_id: str = ""
    google_client_secret: str = ""
    owner_label: str = "Owner photo backup"
    storage_limit: int = 5 * 1024**3
    daily_device_limit: int = 2 * 1024**3
    max_file: int = 512 * 1024**2
    max_pending: int = 1000
    max_receipts: int = 100_000
    testing: bool = False

    @classmethod
    def from_env(cls):
        # Do not include environment values in errors or logs.
        try:
            result = cls(Path(os.environ["FOCAL_DATA"]), os.environ["PUBLIC_BASE_URL"].rstrip("/"),
                         os.environ["TOKEN_ENCRYPTION_KEY"], os.environ["ADMIN_TOKEN"],
                         os.environ["GOOGLE_CLIENT_ID"], os.environ["GOOGLE_CLIENT_SECRET"],
                         os.environ.get("OWNER_LABEL", "Owner photo backup"),
                         int(os.environ.get("STORAGE_BYTES_LIMIT", str(5 * 1024**3))),
                         int(os.environ.get("DEVICE_DAILY_BYTES_LIMIT", str(2 * 1024**3))))
        except (KeyError, ValueError):
            raise RuntimeError("Owner backup configuration is incomplete") from None
        parsed = urlparse(result.public_url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.path or parsed.query or parsed.fragment or parsed.username:
            raise RuntimeError("PUBLIC_BASE_URL must be an HTTPS origin")
        if len(result.admin_token) < 32 or not result.google_client_id.endswith(".apps.googleusercontent.com"):
            raise RuntimeError("Use a strong admin token and a Google web OAuth client")
        return result


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


class Store:
    def __init__(self, settings: Settings):
        self.settings = settings
        settings.data.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.files = settings.data / "files"
        self.files.mkdir(exist_ok=True, mode=0o700)
        self.db_path = settings.data / "backup.sqlite3"
        with self.transaction() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS config(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, token_hash TEXT UNIQUE NOT NULL,
                    label TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS invites(hash TEXT PRIMARY KEY, expires REAL NOT NULL,
                    used INTEGER NOT NULL DEFAULT 0, device_id TEXT, label TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS resources(key TEXT PRIMARY KEY, device_id TEXT NOT NULL,
                    resource_id TEXT NOT NULL, capture_id TEXT NOT NULL, filename TEXT NOT NULL,
                    role TEXT NOT NULL, mime TEXT NOT NULL, day TEXT NOT NULL, captured TEXT NOT NULL,
                    size INTEGER NOT NULL, sha256 TEXT NOT NULL, offset INTEGER NOT NULL DEFAULT 0,
                    state TEXT NOT NULL DEFAULT 'uploading', error TEXT, created REAL NOT NULL,
                    drive_id TEXT, drive_name TEXT, session TEXT, attempts INTEGER NOT NULL DEFAULT 0,
                    retry_at REAL NOT NULL DEFAULT 0, lease_until REAL NOT NULL DEFAULT 0,
                    UNIQUE(device_id, resource_id));
                CREATE TABLE IF NOT EXISTS folders(path TEXT PRIMARY KEY, drive_id TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS oauth_states(hash TEXT PRIMARY KEY, cookie_hash TEXT NOT NULL,
                    verifier TEXT NOT NULL, expires REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS throttle(key TEXT PRIMARY KEY, count INTEGER NOT NULL, expires REAL NOT NULL);
            """)
            db.execute("INSERT OR IGNORE INTO config VALUES('destination',?)", (str(uuid.uuid4()),))
        os.chmod(self.db_path, 0o600)
        self.recover_files()

    @contextlib.contextmanager
    def transaction(self):
        db = sqlite3.connect(self.db_path, timeout=20, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA synchronous=FULL")
        db.execute("BEGIN IMMEDIATE")
        try:
            yield db
            if db.in_transaction:
                db.commit()
        except BaseException:
            if db.in_transaction:
                db.rollback()
            raise
        finally:
            db.close()

    def get(self, key: str):
        with self.transaction() as db:
            row = db.execute("SELECT value FROM config WHERE key=?", (key,)).fetchone()
            return row[0] if row else None

    def set(self, key: str, value: str):
        with self.transaction() as db:
            db.execute("INSERT INTO config VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))

    @property
    def destination(self):
        return self.get("destination")

    def issue_invite(self, label: str, ttl: int = 600, device_id: str | None = None):
        if not 60 <= ttl <= 3600 or not label or len(label.encode()) > 120:
            raise Problem("invalid_invitation")
        code = secrets.token_urlsafe(32)
        with self.transaction() as db:
            if device_id and not db.execute("SELECT 1 FROM devices WHERE id=?", (device_id,)).fetchone():
                raise Problem("unknown_device")
            db.execute("DELETE FROM invites WHERE expires<?", (time.time(),))
            db.execute("INSERT INTO invites VALUES(?,?,0,?,?)", (digest(code), time.time() + ttl, device_id, label))
        return code

    def redeem(self, code: str):
        with self.transaction() as db:
            invite = db.execute("SELECT * FROM invites WHERE hash=?", (digest(code),)).fetchone()
            if not invite or invite["used"] or invite["expires"] < time.time():
                raise Problem("invalid_invitation", 401)
            if db.execute("SELECT COUNT(*) FROM devices").fetchone()[0] >= 100 and not invite["device_id"]:
                raise Problem("device_limit", 429)
            device_id, token = invite["device_id"] or str(uuid.uuid4()), secrets.token_urlsafe(32)
            db.execute("INSERT INTO devices VALUES(?,?,?,0,?) ON CONFLICT(id) DO UPDATE SET token_hash=excluded.token_hash,revoked=0",
                       (device_id, digest(token), invite["label"], time.time()))
            db.execute("UPDATE invites SET used=1 WHERE hash=?", (digest(code),))
            destination = db.execute("SELECT value FROM config WHERE key='destination'").fetchone()[0]
        return {"destinationId": destination, "deviceId": device_id, "deviceToken": token,
                "ownerLabel": self.settings.owner_label}

    def authenticate(self, token: str):
        if len(token) > 256:
            raise Problem("unauthorized", 401)
        with self.transaction() as db:
            row = db.execute("SELECT * FROM devices WHERE token_hash=? AND revoked=0", (digest(token),)).fetchone()
            if not row:
                raise Problem("unauthorized", 401)
            return dict(row)

    def revoke(self, device_id: str):
        with self.transaction() as db:
            db.execute("UPDATE devices SET revoked=1 WHERE id=?", (device_id,))

    def throttle(self, key: str, limit: int, window: int = 60):
        now = time.time()
        with self.transaction() as db:
            db.execute("DELETE FROM throttle WHERE expires<?", (now,))
            row = db.execute("SELECT count FROM throttle WHERE key=?", (key,)).fetchone()
            if (row and row[0] >= limit) or (not row and db.execute("SELECT COUNT(*) FROM throttle").fetchone()[0] >= 20000):
                raise Problem("rate_limit", 429)
            db.execute("INSERT INTO throttle VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET count=count+1", (key, now + window))

    def reserve(self, device_id: str, resource: dict):
        key = digest(device_id + ":" + resource["resourceId"])
        with self.transaction() as db:
            self.require_active(db, device_id)
            old = db.execute("SELECT * FROM resources WHERE key=?", (key,)).fetchone()
            if old:
                if (old["size"], old["sha256"], old["capture_id"], old["role"]) != (resource["size"], resource["sha256"], resource["captureId"], resource["role"]):
                    raise Problem("integrity", 409)
                return dict(old)
            pending = db.execute("SELECT COUNT(*),COALESCE(SUM(size),0) FROM resources WHERE state!='complete'").fetchone()
            if pending[0] >= self.settings.max_pending or pending[1] + resource["size"] > self.settings.storage_limit:
                raise Problem("owner_storage", 507)
            if db.execute("SELECT COUNT(*) FROM resources").fetchone()[0] >= self.settings.max_receipts:
                raise Problem("receipt_limit", 507)
            used = db.execute("SELECT COALESCE(SUM(size),0) FROM resources WHERE device_id=? AND created>?", (device_id, time.time() - 86400)).fetchone()[0]
            if used + resource["size"] > self.settings.daily_device_limit:
                raise Problem("device_daily_quota", 429)
            db.execute("""INSERT INTO resources(key,device_id,resource_id,capture_id,filename,role,mime,day,captured,size,sha256,created)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""", (key, device_id, resource["resourceId"], resource["captureId"],
                resource["filename"], resource["role"], resource["mimeType"], resource["datePath"], resource["createdAt"],
                resource["size"], resource["sha256"], time.time()))
            return dict(db.execute("SELECT * FROM resources WHERE key=?", (key,)).fetchone())

    def resource(self, device_id: str, resource_id: str):
        with self.transaction() as db:
            row = db.execute("SELECT * FROM resources WHERE device_id=? AND resource_id=?", (device_id, resource_id)).fetchone()
            if not row:
                raise Problem("not_found", 404)
            return dict(row)

    @staticmethod
    def require_active(db, device_id):
        active = db.execute("SELECT revoked FROM devices WHERE id=?", (device_id,)).fetchone()
        if not active or active[0]:
            raise Problem("unauthorized", 401)

    def append(self, device_id: str, resource_id: str, start: int, total: int, data: bytes):
        with self.transaction() as db:
            self.require_active(db, device_id)
            row = db.execute("SELECT * FROM resources WHERE device_id=? AND resource_id=?", (device_id, resource_id)).fetchone()
            if not row:
                raise Problem("not_found", 404)
            if row["state"] != "uploading" or row["offset"] != start or row["size"] != total:
                raise Problem("offset_mismatch", 409)
            if not data or start + len(data) > total or len(data) > 4 * 1024**2:
                raise Problem("invalid_chunk", 400)
            import shutil
            if shutil.disk_usage(self.files).free - len(data) < 256 * 1024**2:
                raise Problem("owner_storage", 507)
            path = self.files / (row["key"] + ".bin")
            with path.open("r+b" if path.exists() else "w+b") as output:
                output.seek(0, 2)
                if output.tell() < start:
                    raise Problem("integrity", 409)
                output.truncate(start)  # Undo an uncommitted append after a crash.
                output.seek(start)
                output.write(data)
                output.flush()
                os.fsync(output.fileno())
            os.chmod(path, 0o600)
            directory_fd = os.open(self.files, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            offset = start + len(data)
            state, error = "uploading", None
            if offset == total:
                with path.open("rb") as source:
                    correct = hashlib.file_digest(source, "sha256").hexdigest() == row["sha256"]
                state, error = ("pendingDrive", None) if correct else ("failed", "integrity")
            db.execute("UPDATE resources SET offset=?,state=?,error=? WHERE key=?", (offset, state, error, row["key"]))
            return dict(db.execute("SELECT * FROM resources WHERE key=?", (row["key"],)).fetchone())

    def retry(self, device_id: str, resource_id: str):
        with self.transaction() as db:
            row = db.execute("SELECT * FROM resources WHERE device_id=? AND resource_id=?", (device_id, resource_id)).fetchone()
            if not row:
                return
            path = self.files / (row["key"] + ".bin")
            broken = row["offset"] > 0 and (not path.is_file() or path.stat().st_size < row["offset"])
            if row["state"] != "failed" and not broken:
                return
            if broken or row["error"] in ("integrity", "missing_original"):
                path.unlink(missing_ok=True)
                # Keep any pre-generated Drive ID: a resumed upload still cannot
                # overwrite another file or create a second copy after a lost ACK.
                db.execute("UPDATE resources SET state='uploading',offset=0,error=NULL,attempts=0,retry_at=0,session=NULL WHERE key=?", (row["key"],))
            else:
                db.execute("UPDATE resources SET state='pendingDrive',error=NULL,attempts=0,retry_at=0 WHERE key=?", (row["key"],))

    def claim(self):
        now = time.time()
        with self.transaction() as db:
            row = db.execute("""SELECT r.* FROM resources r JOIN devices d ON d.id=r.device_id
                WHERE d.revoked=0 AND r.state IN ('pendingDrive','uploadingDrive') AND r.retry_at<=? AND r.lease_until<?
                ORDER BY r.created LIMIT 1""", (now, now)).fetchone()
            if not row:
                return None
            db.execute("UPDATE resources SET state='uploadingDrive',lease_until=? WHERE key=?", (now + 300, row["key"]))
            return dict(row)

    def update_resource(self, key: str, **fields):
        allowed = {"drive_id", "drive_name", "session", "state", "error", "attempts", "retry_at", "lease_until"}
        if not fields or not fields.keys() <= allowed:
            raise ValueError("Invalid resource update")
        with self.transaction() as db:
            db.execute("UPDATE resources SET " + ",".join(k + "=?" for k in fields) + " WHERE key=?", (*fields.values(), key))

    def recover_files(self):
        with self.transaction() as db:
            rows = {r["key"]: r for r in db.execute("SELECT * FROM resources")}
            for path in self.files.glob("*.bin"):
                row = rows.get(path.stem)
                if not row or row["state"] == "complete":
                    path.unlink(missing_ok=True)
                elif row["state"] == "uploading" and path.stat().st_size > row["offset"]:
                    with path.open("r+b") as file:
                        file.truncate(row["offset"])

    def response(self, row: dict):
        return {"destinationId": self.destination, "resourceId": row["resource_id"], "state": row["state"],
                "offset": row["offset"], "size": row["size"], "sha256": row["sha256"],
                "driveFileId": row["drive_id"] if row["state"] == "complete" else None, "error": row["error"]}
