"""No real Google credentials, real photos, or external network requests."""
import hashlib
import json
from pathlib import Path
import tempfile
import time
import unittest
from dataclasses import replace
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

from cryptography.fernet import Fernet
import httpx

from focal_backup.app import create_app
from focal_backup.store import Settings, Store, Problem, TARGET_FOLDER_ID
from focal_backup.google_drive import OwnerGoogleAuthorization, GoogleDrive, GoogleFailure, GoogleHTTP, worker_once, DRIVE_SCOPE


class ScriptHTTP:
    def __init__(self, responses=()):
        self.responses = list(responses)
        self.requests = []

    async def send(self, method, url, **kwargs):
        self.requests.append((method, url, kwargs))
        if not self.responses:
            raise AssertionError("Unexpected Google request in local fixture")
        result = self.responses.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


class Base(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.settings = Settings(Path(self.tmp.name), "https://backup.example", Fernet.generate_key().decode(),
                                 "mock-owner-admin-" * 3, "mock.apps.googleusercontent.com", "mock-web-client-secret")
        self.app = create_app(self.settings, run_worker=False)
        self.store = self.app.state.store
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url=self.settings.public_url)
        invite = self.store.issue_invite("Fixture phone")
        self.grant = self.store.redeem(invite)
        self.headers = {"Authorization": "Bearer " + self.grant["deviceToken"], "X-Focal-Destination": self.store.destination}
        self.bytes = b"fixture-original-with-metadata-\x00\xff-not-a-user-photo"

    async def asyncTearDown(self):
        await self.client.aclose()
        self.tmp.cleanup()

    def body(self, data=None, **changes):
        data = self.bytes if data is None else data
        value = {"resourceId": "fixture-photo", "captureId": "fixture-capture", "destinationId": self.store.destination,
                 "filename": "original.heic", "role": "original", "mimeType": "image/heic", "datePath": "2026/10/17",
                 "createdAt": "2026-10-17T12:00:00Z", "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        value.update(changes)
        return value

    async def reserve(self, body=None):
        return await self.client.post("/v1/resources", headers=self.headers, json=body or self.body())

    async def put(self, data, start=0, total=None):
        headers = dict(self.headers, **{"Content-Range": f"bytes {start}-{start+len(data)-1}/{total or len(self.bytes)}"})
        return await self.client.put("/v1/resources/fixture-photo/data", headers=headers, content=data)

    async def pending(self):
        self.assertEqual((await self.reserve()).status_code, 200)
        self.assertEqual((await self.put(self.bytes)).json()["state"], "pendingDrive")
        return self.store.resource(self.grant["deviceId"], "fixture-photo")

    @staticmethod
    def folder_ok():
        return 200, {}, {"id": TARGET_FOLDER_ID, "mimeType": "application/vnd.google-apps.folder",
                         "trashed": False, "capabilities": {"canAddChildren": True}}

    def authorize(self, http=None):
        auth = OwnerGoogleAuthorization(self.store, http)
        self.store.set("google_tokens", auth.encrypt({"access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_at": time.time()+3600}))
        self.store.set("google_status", "active")
        self.store.set("folder_status", "verified")
        return auth


class DeviceTests(Base):
    async def test_enrollment_needs_only_invitation_and_returns_no_google_secret(self):
        code = self.store.issue_invite("Friend")
        reply = await self.client.post("/v1/enroll", json={"code": code})
        self.assertEqual(reply.status_code, 200)
        self.assertEqual(set(reply.json()), {"deviceId", "destinationId", "deviceToken", "ownerLabel"})
        self.assertNotIn("fixture-refresh", reply.text)
        self.assertEqual((await self.client.post("/v1/enroll", json={"code": code})).status_code, 401)
        self.assertNotIn(code, self.store.db_path.read_bytes().decode(errors="ignore"))

    async def test_expired_invitation_rejected(self):
        code = self.store.issue_invite("Friend")
        with self.store.transaction() as db:
            db.execute("UPDATE invites SET expires=0")
        self.assertEqual((await self.client.post("/v1/enroll", json={"code": code})).status_code, 401)

    async def test_recovery_keeps_device_id_and_rotates_token(self):
        code = self.store.issue_invite("Recover", device_id=self.grant["deviceId"])
        replacement = self.store.redeem(code)
        self.assertEqual(replacement["deviceId"], self.grant["deviceId"])
        self.assertNotEqual(replacement["deviceToken"], self.grant["deviceToken"])
        self.assertEqual((await self.client.get("/v1/status", headers=self.headers)).status_code, 401)

    async def test_revocation_prevents_upload_and_worker_claim(self):
        await self.pending()
        self.store.revoke(self.grant["deviceId"])
        self.assertIsNone(self.store.claim())
        self.assertEqual((await self.client.get("/v1/status", headers=self.headers)).status_code, 401)

    async def test_revocation_rechecked_when_upload_body_arrives(self):
        await self.reserve()
        self.store.revoke(self.grant["deviceId"])
        with self.assertRaises(Problem) as error:
            self.store.append(self.grant["deviceId"], "fixture-photo", 0, len(self.bytes), self.bytes)
        self.assertEqual(error.exception.status, 401)

    async def test_other_device_cannot_read_or_overwrite_resource(self):
        await self.pending()
        other = self.store.redeem(self.store.issue_invite("Another"))
        headers = dict(self.headers, Authorization="Bearer "+other["deviceToken"])
        reply = await self.client.get("/v1/resources/fixture-photo", headers=headers)
        self.assertEqual(reply.status_code, 404)
        self.assertEqual((await self.client.get("/v1/resources", headers=headers)).status_code, 405)

    async def test_destination_mismatch_is_explicit(self):
        reply = await self.client.get("/v1/status", headers=dict(self.headers, **{"X-Focal-Destination": "other-owner"}))
        self.assertEqual(reply.status_code, 409)
        self.assertEqual(reply.json()["error"], "destination_mismatch")

    async def test_https_required_even_with_valid_token(self):
        reply = await self.client.get("http://backup.example/v1/status", headers=self.headers)
        self.assertEqual(reply.status_code, 400)
        self.assertNotIn(self.grant["deviceToken"], reply.text)

    async def test_malicious_filename_and_date_are_rejected(self):
        for changes in ({"filename": "../secret"}, {"filename": "line\nname"}, {"datePath": "2026/02/31"}, {"size": True}, {"sha256": "bad"}):
            with self.subTest(changes=changes):
                reply = await self.reserve(self.body(**changes))
                self.assertEqual(reply.status_code, 400)

    async def test_duplicate_reservation_is_idempotent(self):
        first = await self.reserve()
        second = await self.reserve()
        self.assertEqual(first.json(), second.json())
        with self.store.transaction() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM resources").fetchone()[0], 1)

    async def test_changed_content_cannot_reuse_resource_identity(self):
        await self.reserve()
        reply = await self.reserve(self.body(sha256="0"*64))
        self.assertEqual(reply.status_code, 409)

    async def test_chunk_offsets_survive_restart_and_lost_ack(self):
        await self.reserve()
        first = await self.put(self.bytes[:10], total=len(self.bytes))
        self.assertEqual(first.json()["offset"], 10)
        self.assertEqual((await self.put(self.bytes[:10], total=len(self.bytes))).status_code, 409)
        restarted = Store(self.settings)
        self.assertEqual(restarted.resource(self.grant["deviceId"], "fixture-photo")["offset"], 10)
        final = await self.put(self.bytes[10:], start=10)
        self.assertEqual(final.json()["state"], "pendingDrive")
        self.assertIsNone(final.json()["driveFileId"])

    async def test_uncommitted_tail_removed_after_crash(self):
        await self.reserve()
        await self.put(self.bytes[:10])
        row = self.store.resource(self.grant["deviceId"], "fixture-photo")
        path = self.store.files/(row["key"]+".bin")
        with path.open("ab") as file:
            file.write(b"uncommitted-tail")
        Store(self.settings)
        self.assertEqual(path.read_bytes(), self.bytes[:10])

    async def test_corrupt_bytes_never_reach_drive_worker(self):
        await self.reserve()
        wrong = b"X"*len(self.bytes)
        reply = await self.put(wrong)
        self.assertEqual(reply.json()["state"], "failed")
        self.assertEqual(reply.json()["error"], "integrity")
        self.assertIsNone(self.store.claim())

    async def test_retry_integrity_resets_offset_and_preserves_record(self):
        await self.reserve()
        await self.put(b"X"*len(self.bytes))
        self.store.retry(self.grant["deviceId"], "fixture-photo")
        row = self.store.resource(self.grant["deviceId"], "fixture-photo")
        self.assertEqual(row["offset"], 0)
        self.assertEqual((await self.put(self.bytes)).json()["state"], "pendingDrive")

    async def test_raw_bytes_remain_identical(self):
        reply = await self.reserve(self.body(filename="original.dng", role="raw", mimeType="image/x-adobe-dng"))
        self.assertEqual(reply.status_code, 200)
        await self.put(self.bytes)
        row = self.store.resource(self.grant["deviceId"], "fixture-photo")
        self.assertEqual((self.store.files/(row["key"]+".bin")).read_bytes(), self.bytes)

    async def test_storage_and_daily_quotas_are_bounded(self):
        small = Store(replace(self.settings, data=Path(self.tmp.name)/"small", storage_limit=5))
        grant = small.redeem(small.issue_invite("test"))
        with self.assertRaises(Problem) as error:
            small.reserve(grant["deviceId"], self.body())
        self.assertEqual(error.exception.code, "owner_storage")
        daily = Store(replace(self.settings, data=Path(self.tmp.name)/"daily", daily_device_limit=5))
        grant = daily.redeem(daily.issue_invite("test"))
        with self.assertRaises(Problem) as error:
            daily.reserve(grant["deviceId"], self.body())
        self.assertEqual(error.exception.code, "device_daily_quota")

    async def test_oversized_chunk_and_missing_auth_are_rejected(self):
        self.assertEqual((await self.client.get("/v1/status")).status_code, 401)
        await self.reserve()
        headers = dict(self.headers, **{"Content-Range": "bytes 0-5000000/6000000"})
        self.assertEqual((await self.client.put("/v1/resources/fixture-photo/data", headers=headers, content=b"fixture")).status_code, 400)


class OAuthTests(Base):
    async def test_pkce_state_is_one_use_and_encrypted(self):
        auth = OwnerGoogleAuthorization(self.store, ScriptHTTP())
        url, cookie = auth.begin()
        params = parse_qs(urlparse(url).query)
        self.assertEqual(params["scope"], [DRIVE_SCOPE])
        self.assertEqual(params["code_challenge_method"], ["S256"])
        self.assertEqual(params["redirect_uri"], ["https://backup.example/admin/google/callback"])
        with self.assertRaises(Problem):
            await auth.complete("fixture-code", params["state"][0], "wrong-cookie")
        with self.store.transaction() as db:
            row = db.execute("SELECT * FROM oauth_states").fetchone()
        verifier = auth.decrypt(row["verifier"])
        self.assertNotIn(verifier, row["verifier"])
        self.assertNotIn(cookie, row["cookie_hash"])

    async def test_owner_authorization_encrypts_tokens_and_consumes_state(self):
        http = ScriptHTTP([(200, {}, {"access_token": "mock-access", "refresh_token": "mock-refresh", "scope": DRIVE_SCOPE}),
                           (200, {}, {"user": {"permissionId": "mock-owner"}})])
        auth = OwnerGoogleAuthorization(self.store, http)
        url, cookie = auth.begin()
        state = parse_qs(urlparse(url).query)["state"][0]
        await auth.complete("mock-code", state, cookie)
        self.assertTrue(auth.connected)
        self.assertNotIn("mock-refresh", self.store.get("google_tokens"))
        self.assertEqual(auth.decrypt(self.store.get("google_tokens"))["refresh_token"], "mock-refresh")
        self.assertIn("code_verifier", http.requests[0][2]["form"])
        with self.assertRaises(Problem):
            await auth.complete("mock-code", state, cookie)

    async def test_different_google_owner_cannot_reroute_device_uploads(self):
        http = ScriptHTTP([(200, {}, {"access_token": "mock-access", "refresh_token": "mock-refresh", "scope": DRIVE_SCOPE}),
                           (200, {}, {"user": {"permissionId": "other-owner"}})])
        auth = self.authorize(http)
        self.store.set("google_owner", "previous-owner-hash")
        saved = self.store.get("google_tokens")
        url, cookie = auth.begin()
        state = parse_qs(urlparse(url).query)["state"][0]
        with self.assertRaises(Problem) as error:
            await auth.complete("mock-code", state, cookie)
        self.assertEqual(error.exception.code, "different_google_owner")
        self.assertEqual(saved, self.store.get("google_tokens"))

    async def test_expired_access_token_refresh_preserves_refresh_token(self):
        http = ScriptHTTP([(200, {}, {"access_token": "new-mock-access", "expires_in": 3600})])
        auth = self.authorize(http)
        tokens = auth.decrypt(self.store.get("google_tokens")); tokens["expires_at"] = 0
        self.store.set("google_tokens", auth.encrypt(tokens))
        self.assertEqual(await auth.access_token(), "new-mock-access")
        self.assertEqual(auth.decrypt(self.store.get("google_tokens"))["refresh_token"], "fixture-refresh")

    async def test_invalid_grant_requires_owner_reauthorization(self):
        auth = self.authorize(ScriptHTTP([(400, {}, {"error": "invalid_grant"})]))
        with self.assertRaises(GoogleFailure) as error:
            await auth.access_token(force=True)
        self.assertEqual(error.exception.code, "owner_authorization")
        self.assertFalse(auth.connected)

    async def test_drive_401_refreshes_once_then_uses_new_access_token(self):
        http = ScriptHTTP([(401, {}, {}), (200, {}, {"access_token": "refreshed-fixture"}), (200, {}, {"ids": ["stable-fixture-id"]})])
        drive = GoogleDrive(self.authorize(http))
        self.assertEqual(await drive.generate_id(), "stable-fixture-id")
        self.assertEqual(http.requests[-1][2]["token"], "refreshed-fixture")

    async def test_admin_requires_secret_and_same_origin_and_secure_cookie(self):
        headers = {"Origin": self.settings.public_url, "Content-Type": "application/x-www-form-urlencoded"}
        self.assertEqual((await self.client.post("/admin/google/start", headers=headers, content="admin_token=wrong")).status_code, 401)
        reply = await self.client.post("/admin/google/start", headers=headers, content="admin_token="+self.settings.admin_token)
        self.assertEqual(reply.status_code, 303)
        self.assertIn("Secure", reply.headers["set-cookie"])
        self.assertIn("HttpOnly", reply.headers["set-cookie"])
        self.assertNotIn(self.settings.admin_token, reply.headers["location"])

    async def test_google_transport_rejects_redirect_destinations_before_network(self):
        for url in ["http://www.googleapis.com/drive/v3/files", "https://attacker.example/upload/drive/v3/files", "https://user:secret@www.googleapis.com/drive/v3/files"]:
            with self.assertRaises(GoogleFailure):
                await GoogleHTTP().send("PUT", url)


class DriveTests(Base):
    async def test_pending_resource_completes_only_after_verified_adapter(self):
        row = await self.pending()
        class VerifiedFixtureDrive:
            async def upload(inner, resource):
                self.assertEqual(resource["sha256"], hashlib.sha256(self.bytes).hexdigest())
                self.assertEqual((self.store.files/(resource["key"]+".bin")).read_bytes(), self.bytes)
                return "verified-fixture-drive-id"
        await worker_once(self.store, VerifiedFixtureDrive())
        reply = await self.client.get("/v1/resources/fixture-photo", headers=self.headers)
        self.assertEqual(reply.json()["state"], "complete")
        self.assertEqual(reply.json()["driveFileId"], "verified-fixture-drive-id")
        self.assertFalse((self.store.files/(row["key"]+".bin")).exists())

    async def test_drive_quota_preserves_original_and_no_completion(self):
        row = await self.pending()
        class FullFixtureDrive:
            async def upload(inner, resource):
                raise GoogleFailure("drive_quota")
        await worker_once(self.store, FullFixtureDrive())
        resource = self.store.resource(self.grant["deviceId"], "fixture-photo")
        self.assertEqual(resource["state"], "pendingDrive")
        self.assertEqual(resource["error"], "drive_quota")
        self.assertGreater(resource["retry_at"], time.time()+290)
        self.assertTrue((self.store.files/(row["key"]+".bin")).exists())

    async def test_integrity_verification_requires_size_owner_and_checksum(self):
        row = await self.pending()
        drive = GoogleDrive(self.authorize())
        meta = {"id": "fixture-id", "size": str(row["size"]), "sha256Checksum": row["sha256"],
                "parents": [TARGET_FOLDER_ID], "appProperties": {"focalResource": row["key"], "focalDestination": self.store.destination}}
        self.assertTrue(drive.verified(meta, row))
        self.assertFalse(drive.verified(dict(meta, size="0"), row))
        self.assertFalse(drive.verified(dict(meta, sha256Checksum="wrong", md5Checksum="correct-md5"), row, "correct-md5"))
        self.assertFalse(drive.verified(dict(meta, appProperties={}), row))
        self.assertFalse(drive.verified(dict(meta, trashed=True), row))

    async def test_actual_resumable_request_flow_and_exact_bytes(self):
        row = await self.pending()
        metadata = {"id": "pre-generated-fixture", "size": str(row["size"]), "sha256Checksum": row["sha256"],
                    "parents": [TARGET_FOLDER_ID], "appProperties": {"focalResource": row["key"], "focalDestination": self.store.destination}}
        http = ScriptHTTP([self.folder_ok(), (200, {}, {"files": []}), (200, {}, {"ids": ["pre-generated-fixture"]}), (200, {}, {"files": []}),
                           (200, {"location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture"}, {}),
                           (200, {}, {"id": "pre-generated-fixture"}), (200, {}, metadata)])
        drive = GoogleDrive(self.authorize(http))
        self.assertEqual(await drive.upload(row), "pre-generated-fixture")
        initiate = http.requests[4]
        self.assertEqual(initiate[2]["body"]["id"], "pre-generated-fixture")
        self.assertEqual(initiate[2]["body"]["mimeType"], "image/heic")
        self.assertEqual(initiate[2]["body"]["parents"], [TARGET_FOLDER_ID])
        self.assertEqual(http.requests[5][2]["data"], self.bytes)
        self.assertEqual(http.requests[5][2]["headers"]["Content-Range"], f"bytes 0-{len(self.bytes)-1}/{len(self.bytes)}")
        saved = self.store.resource(self.grant["deviceId"], "fixture-photo")
        self.assertNotIn("upload_id=fixture", saved["session"])

    async def test_resume_uses_google_range_not_assumed_local_offset(self):
        row = await self.pending()
        meta = {"id": "existing-fixture", "size": str(row["size"]), "sha256Checksum": row["sha256"],
                "parents": [TARGET_FOLDER_ID], "appProperties": {"focalResource": row["key"], "focalDestination": self.store.destination}}
        http = ScriptHTTP([self.folder_ok(), (404, {}, {}), (200, {}, {"files": []}), (308, {"range": "bytes=0-9"}, {}), (200, {}, {}), (200, {}, meta)])
        auth = self.authorize(http); drive = GoogleDrive(auth)
        row.update(drive_id="existing-fixture", drive_name="original.heic", session=auth.encrypt("https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture"))
        self.assertEqual(await drive.upload(row), "existing-fixture")
        self.assertEqual(http.requests[3][2]["headers"]["Content-Range"], f"bytes */{len(self.bytes)}")
        self.assertEqual(http.requests[4][2]["data"], self.bytes[10:])

    async def test_preexisting_verified_id_avoids_duplicate_upload(self):
        row = await self.pending(); row["drive_id"] = "existing-fixture"
        meta = {"id": "existing-fixture", "size": str(row["size"]), "sha256Checksum": row["sha256"],
                "parents": [TARGET_FOLDER_ID], "appProperties": {"focalResource": row["key"], "focalDestination": self.store.destination}}
        http = ScriptHTTP([self.folder_ok(), (200, {}, meta)])
        self.assertEqual(await GoogleDrive(self.authorize(http)).upload(row), "existing-fixture")
        self.assertEqual(len(http.requests), 2)

    async def test_exact_existing_folder_is_verified_without_creating_any_folder(self):
        auth = self.authorize(ScriptHTTP([self.folder_ok()]))
        self.assertEqual(await GoogleDrive(auth).verify_target_folder(), TARGET_FOLDER_ID)
        self.assertEqual(len(auth.http.requests), 1)
        self.assertEqual(auth.http.requests[0][0], "GET")
        self.assertIn("/files/" + TARGET_FOLDER_ID + "?", auth.http.requests[0][1])
        self.assertIn("capabilities(canAddChildren)", auth.http.requests[0][1])

    async def test_corrupt_server_original_blocks_google_before_network(self):
        row = await self.pending()
        (self.store.files/(row["key"]+".bin")).write_bytes(b"corrupt")
        http = ScriptHTTP()
        with self.assertRaises(GoogleFailure) as error:
            await GoogleDrive(self.authorize(http)).upload(row)
        self.assertEqual(error.exception.code, "integrity")
        self.assertFalse(http.requests)

    async def test_retry_budget_stops_temporary_failures(self):
        row = await self.pending()
        self.store.update_resource(row["key"], attempts=7)
        class FailingDrive:
            async def upload(self, resource): raise GoogleFailure("google_temporary")
        await worker_once(self.store, FailingDrive())
        self.assertEqual(self.store.resource(self.grant["deviceId"], "fixture-photo")["state"], "failed")

    async def test_invalid_range_is_not_accepted(self):
        for value in ["bytes=1-9", "bytes=0-999", "bytes=0-nan"]:
            with self.assertRaises(GoogleFailure): GoogleDrive.offset(value, 100)
        self.assertEqual(GoogleDrive.offset("bytes=0-9", 100), 10)
        self.assertEqual(GoogleDrive.offset(None, 100), 0)


if __name__ == "__main__":
    unittest.main()
