"""Exact-folder fixtures: no Google account, user photo or external HTTP."""
import hashlib
import time
from dataclasses import replace
from urllib.parse import parse_qs, urlparse
import httpx
from test_backup import Base, ScriptHTTP
from focal_backup.app import create_app
from focal_backup.store import Store, TARGET_FOLDER_ID
from focal_backup.google_drive import GoogleDrive, GoogleFailure, DRIVE_SCOPE, worker_once


class ExactFolderTests(Base):
    async def test_missing_readonly_trashed_or_wrong_folder_blocks_all_uploads(self):
        row = await self.pending()
        fixtures = [(404, {}, {}), (403, {}, {"error": {"errors": [{"reason": "insufficientFilePermissions"}]}})]
        for changes in ({"id": "wrong"}, {"trashed": True}, {"mimeType": "image/jpeg"},
                        {"capabilities": {}}, {"capabilities": {"canAddChildren": False}}):
            fixtures.append((200, {}, dict(self.folder_ok()[2], **changes)))
        for reply in fixtures:
            with self.subTest(reply=reply):
                http = ScriptHTTP([reply])
                with self.assertRaises(GoogleFailure) as error:
                    await GoogleDrive(self.authorize(http)).upload(row)
                self.assertEqual(error.exception.code, "folder_authorization")
                self.assertEqual(self.store.get("folder_status"), "unavailable")
                self.assertEqual([r[0] for r in http.requests], ["GET"])
                self.assertTrue((self.store.files/(row["key"]+".bin")).exists())

    async def test_oauth_alone_does_not_grant_existing_folder_access(self):
        row = await self.pending(); http = ScriptHTTP()
        drive = GoogleDrive(self.authorize(http))
        self.store.set("folder_status", "needs_selection")
        with self.assertRaises(GoogleFailure) as error:
            await drive.upload(row)
        self.assertEqual(error.exception.code, "folder_authorization")
        self.assertFalse(http.requests)

    async def test_rate_limited_folder_read_preserves_retry_after(self):
        http = ScriptHTTP([(403, {"retry-after": "120"}, {"error": {"errors": [{"reason": "rateLimitExceeded"}]}})])
        drive = GoogleDrive(self.authorize(http))
        with self.assertRaises(GoogleFailure) as error:
            await drive.verify_target_folder()
        self.assertEqual(error.exception.code, "google_rate_limited")
        self.assertEqual(error.exception.retry_after, 120)
        self.assertEqual(self.store.get("folder_status"), "verified")

    async def test_permission_loss_preserves_original_and_recovers_without_new_id(self):
        row = await self.pending()
        self.store.update_resource(row["key"], drive_id="reserved-fixture")
        drive = GoogleDrive(self.authorize(ScriptHTTP([(404, {}, {})])))
        await worker_once(self.store, drive)
        saved = self.store.resource(self.grant["deviceId"], "fixture-photo")
        self.assertEqual(saved["state"], "pendingDrive")
        self.assertEqual(saved["error"], "folder_authorization")
        self.assertEqual(saved["drive_id"], "reserved-fixture")
        self.assertGreater(saved["retry_at"], time.time()+290)
        drive.http = ScriptHTTP([self.folder_ok()])
        self.assertEqual(await drive.verify_target_folder(), TARGET_FOLDER_ID)
        self.assertEqual(self.store.get("folder_status"), "verified")

    async def test_google_rate_limit_remains_retryable_after_burst_budget(self):
        row = await self.pending(); self.store.update_resource(row["key"], attempts=8)
        class LimitedDrive:
            async def upload(self, row): raise GoogleFailure("google_rate_limited", 86400)
        await worker_once(self.store, LimitedDrive())
        deferred = self.store.resource(self.grant["deviceId"], "fixture-photo")
        self.assertEqual(deferred["state"], "pendingDrive"); self.assertEqual(deferred["attempts"], 8)
        self.assertGreater(deferred["retry_at"], time.time()+86390)
        self.assertTrue((self.store.files/(row["key"]+".bin")).exists())

    async def test_permission_lost_after_preflight_is_a_recoverable_owner_error(self):
        row = await self.pending()
        class RevokedDuringTransfer:
            async def upload(self, row): raise GoogleFailure("drive_permission")
        await worker_once(self.store, RevokedDuringTransfer())
        deferred = self.store.resource(self.grant["deviceId"], "fixture-photo")
        self.assertEqual(deferred["state"], "pendingDrive")
        self.assertEqual(deferred["error"], "folder_authorization")
        self.assertEqual(self.store.get("folder_status"), "unavailable")
        self.assertTrue((self.store.files/(row["key"]+".bin")).exists())

    async def test_correct_hash_in_wrong_parent_is_not_success(self):
        row = await self.pending(); drive = GoogleDrive(self.authorize())
        meta = {"id": "fixture", "size": row["size"], "sha256Checksum": row["sha256"],
                "appProperties": {"focalResource": row["key"], "focalDestination": self.store.destination}}
        for parents in (None, [], ["root"], ["unrelated"], [TARGET_FOLDER_ID, "other"]):
            self.assertFalse(drive.verified(dict(meta, parents=parents), row))
        self.assertTrue(drive.verified(dict(meta, parents=[TARGET_FOLDER_ID]), row))
        md5 = hashlib.md5(self.bytes).hexdigest()
        self.assertTrue(drive.verified(dict(meta, parents=[TARGET_FOLDER_ID], sha256Checksum=None, md5Checksum=md5), row, md5))

    async def test_moved_existing_capture_is_not_duplicated_or_moved_back(self):
        row = await self.pending()
        meta = {"id": "existing", "parents": ["elsewhere"], "size": row["size"], "sha256Checksum": row["sha256"],
                "appProperties": {"focalResource": row["key"], "focalDestination": self.store.destination}}
        for known in (True, False):
            row["drive_id"] = "existing" if known else None
            replies = [self.folder_ok()] + ([] if known else [(200, {}, {"files": [{"id": "existing"}]})]) + [(200, {}, meta)]
            http = ScriptHTTP(replies)
            with self.assertRaises(GoogleFailure):
                await GoogleDrive(self.authorize(http)).upload(row)
            self.assertTrue(all(r[0] == "GET" for r in http.requests))

    async def upload_fixture(self, *, parents=None, names=None, raw=False):
        if raw:
            self.bytes = b"II\x2a\x00RAW-fixture-original-EXIF\xff\x00" * 100
            await self.reserve(self.body(filename="original.dng", mimeType="image/x-adobe-dng", role="raw"))
            await self.put(self.bytes)
            row = self.store.resource(self.grant["deviceId"], "fixture-photo")
        else:
            row = await self.pending()
        meta = {"id": "reserved", "parents": parents or [TARGET_FOLDER_ID], "size": row["size"], "sha256Checksum": row["sha256"],
                "appProperties": {"focalResource": row["key"], "focalDestination": self.store.destination}}
        http = ScriptHTTP([self.folder_ok(), (200, {}, {"files": []}), (200, {}, {"ids": ["reserved"]}),
                           (200, {}, {"files": names or []}),
                           (200, {"location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture"}, {}),
                           (200, {}, {"id": "reserved"}), (200, {}, meta)])
        await worker_once(self.store, GoogleDrive(self.authorize(http)))
        return row, http

    async def test_wrong_final_parent_never_returns_completed_receipt(self):
        row, _ = await self.upload_fixture(parents=["root"])
        status = (await self.client.get("/v1/resources/fixture-photo", headers=self.headers)).json()
        self.assertEqual(status["state"], "failed"); self.assertEqual(status["error"], "integrity")
        self.assertIsNone(status["driveFileId"])
        self.assertTrue((self.store.files/(row["key"]+".bin")).exists())

    async def test_collision_is_deterministic_and_never_overwrites_unrelated_files(self):
        row, http = await self.upload_fixture(names=[{"id": "unrelated"}])
        body = http.requests[4][2]["body"]
        self.assertEqual(body["name"], "original--"+row["key"][:10]+".heic")
        self.assertEqual(body["parents"], [TARGET_FOLDER_ID])
        self.assertEqual(body["appProperties"]["focalDate"], "2026/10/17")
        self.assertEqual(body["appProperties"]["focalRole"], "original")
        self.assertFalse(any(r[0] in ("PATCH", "DELETE") for r in http.requests))

    async def test_raw_resumable_upload_preserves_bytes_and_exact_parent(self):
        _, http = await self.upload_fixture(raw=True)
        self.assertEqual(http.requests[4][2]["body"]["mimeType"], "image/x-adobe-dng")
        self.assertEqual(http.requests[4][2]["body"]["parents"], [TARGET_FOLDER_ID])
        self.assertEqual(http.requests[5][2]["data"], self.bytes)
        self.assertEqual(self.store.resource(self.grant["deviceId"], "fixture-photo")["state"], "complete")

    async def test_restart_keeps_binding_but_legacy_or_retargeted_data_is_rejected(self):
        row = await self.pending()
        self.assertEqual(Store(self.settings).resource(self.grant["deviceId"], "fixture-photo")["key"], row["key"])
        for target in (None, "different-folder"):
            with self.store.transaction() as db:
                db.execute("DELETE FROM config WHERE key='target_folder'")
                if target: db.execute("INSERT INTO config VALUES('target_folder',?)", (target,))
            with self.assertRaisesRegex(RuntimeError, "fresh exact-folder data volume"):
                Store(self.settings)
            self.assertTrue((self.store.files/(row["key"]+".bin")).exists())


class OwnerFolderTests(Base):
    def session(self):
        cookie, csrf = self.store.owner_session()
        self.client.cookies.set("focal_owner_setup", cookie, domain="backup.example", path="/admin")
        self.client.cookies.set("focal_owner_csrf", csrf, domain="backup.example", path="/admin")
        return {"Origin": self.settings.public_url, "X-Focal-CSRF": csrf}

    async def test_device_credential_cannot_access_owner_picker_or_google_token(self):
        for path in ("/admin/folder", "/admin/folder.js", "/admin/folder/config"):
            response = await self.client.get(path, headers=self.headers)
            self.assertEqual(response.status_code, 401)
            self.assertNotIn("fixture-access", response.text)
        response = await self.client.post("/admin/folder/confirm", headers=self.headers, json={"folderId": TARGET_FOLDER_ID})
        self.assertIn(response.status_code, (401, 403))

    async def test_folder_confirmation_requires_origin_csrf_and_actual_google_feedback(self):
        headers = self.session(); self.app.state.drive.http = ScriptHTTP([self.folder_ok()]); self.authorize()
        for override in ({"Origin": "https://attacker.example"}, {"X-Focal-CSRF": "wrong"}):
            response = await self.client.post("/admin/folder/confirm", headers=dict(headers, **override), json={"folderId": TARGET_FOLDER_ID})
            self.assertEqual(response.status_code, 403)
        wrong = await self.client.post("/admin/folder/confirm", headers=headers, json={"folderId": "another-folder"})
        self.assertEqual(wrong.status_code, 400); self.assertFalse(self.app.state.drive.http.requests)
        good = await self.client.post("/admin/folder/confirm", headers=headers, json={"folderId": TARGET_FOLDER_ID})
        self.assertEqual(good.json(), {"verified": True, "targetFolderId": TARGET_FOLDER_ID})
        self.assertEqual(len(self.app.state.drive.http.requests), 1)
        self.assertEqual((await self.client.get("/admin/folder/config")).status_code, 401)

    async def test_picker_callback_cannot_fabricate_permission(self):
        headers = self.session(); self.authorize(); self.app.state.drive.http = ScriptHTTP([(404, {}, {})])
        reply = await self.client.post("/admin/folder/confirm", headers=headers, json={"folderId": TARGET_FOLDER_ID})
        self.assertEqual(reply.status_code, 503); self.assertEqual(self.store.get("folder_status"), "unavailable")
        status = (await self.client.get("/v1/status", headers=self.headers)).json()
        self.assertFalse(status["driveConnected"]); self.assertEqual(status["error"], "folder_authorization")

    async def test_owner_session_expires_and_stores_only_hashes(self):
        headers = self.session()
        with self.store.transaction() as db:
            row = db.execute("SELECT * FROM owner_sessions").fetchone()
            self.assertNotEqual(row["csrf_hash"], headers["X-Focal-CSRF"])
            db.execute("UPDATE owner_sessions SET expires=0")
        self.assertEqual((await self.client.get("/admin/folder")).status_code, 401)

    async def test_oauth_callback_opens_secure_setup_and_does_not_skip_folder_selection(self):
        self.app.state.authorization.http = ScriptHTTP([
            (200, {}, {"access_token": "mock-access", "refresh_token": "mock-refresh", "scope": DRIVE_SCOPE}),
            (200, {}, {"user": {"permissionId": "mock-owner"}})])
        url, cookie = self.app.state.authorization.begin()
        self.client.cookies.set("focal_owner_oauth", cookie, domain="backup.example", path="/admin")
        state = parse_qs(urlparse(url).query)["state"][0]
        response = await self.client.get("/admin/google/callback", params={"code": "fixture-code", "state": state})
        self.assertEqual(response.status_code, 303); self.assertEqual(response.headers["location"], "/admin/folder")
        self.assertTrue(all("Secure" in c and "HttpOnly" in c for c in response.headers.get_list("set-cookie")))
        self.assertEqual(self.store.get("folder_status"), "needs_selection")
        self.assertFalse((await self.client.get("/v1/status", headers=self.headers)).json()["driveConnected"])
        self.assertNotIn("mock-refresh", response.text + str(response.headers))

    async def test_owner_page_has_picker_policy_without_tokens(self):
        self.session(); response = await self.client.get("/admin/folder")
        self.assertEqual(response.status_code, 200)
        self.assertIn("https://apis.google.com", response.headers["content-security-policy"])
        self.assertIn("frame-ancestors 'none'", response.headers["content-security-policy"])
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertEqual(response.headers["referrer-policy"], "strict-origin-when-cross-origin")
        self.assertIn(TARGET_FOLDER_ID, response.text); self.assertNotIn("refresh_token", response.text)

    async def test_only_owner_browser_config_gets_short_lived_access_token(self):
        configured = replace(self.settings, google_picker_key="fixture-restricted-picker-key", google_project_number="1234567890")
        app = create_app(configured, run_worker=False); self.authorize(); cookie, csrf = self.store.owner_session()
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url=configured.public_url,
                                     cookies={"focal_owner_setup": cookie, "focal_owner_csrf": csrf}) as client:
            response = await client.get("/admin/folder/config")
        self.assertEqual(response.status_code, 200); self.assertEqual(response.json()["targetFolderId"], TARGET_FOLDER_ID)
        self.assertEqual(response.json()["accessToken"], "fixture-access")
        self.assertNotIn("fixture-refresh", response.text); self.assertNotIn(self.settings.google_client_secret, response.text)
        self.assertEqual(response.headers["cache-control"], "no-store")

    async def test_missing_picker_configuration_fails_closed(self):
        self.session(); response = await self.client.get("/admin/folder/config")
        self.assertEqual(response.status_code, 503); self.assertEqual(response.json()["error"], "picker_not_configured")
