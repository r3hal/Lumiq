from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from datetime import datetime
import hmac
import json
import re
import unicodedata

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from starlette.middleware.trustedhost import TrustedHostMiddleware

from .store import Store, Settings, Problem, digest
from .google_drive import OwnerGoogleAuthorization, GoogleDrive, GoogleFailure, worker_once

ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
SHA = re.compile(r"^[a-f0-9]{64}$")
ROLES = {"photo", "original", "raw", "scan", "widePreview", "metadata"}
MIMES = {"image/jpeg", "image/heic", "image/x-adobe-dng", "application/json"}


async def bounded_body(request: Request, limit: int):
    result = bytearray()
    async for chunk in request.stream():
        if len(result) + len(chunk) > limit:
            raise Problem("body_too_large", 413)
        result.extend(chunk)
    return bytes(result)


async def object_body(request: Request):
    try:
        value = json.loads(await bounded_body(request, 16384))
        if not isinstance(value, dict):
            raise ValueError()
        return value
    except (ValueError, UnicodeDecodeError):
        raise Problem("invalid_request", 400) from None


def validate_resource(body, settings):
    required = {"resourceId", "captureId", "destinationId", "filename", "role", "mimeType", "datePath", "createdAt", "size", "sha256"}
    if body.keys() != required or any(not isinstance(body[k], str) for k in required - {"size"}):
        raise Problem("invalid_request")
    if not all(ID.fullmatch(body[k]) for k in ["resourceId", "captureId", "destinationId"]):
        raise Problem("invalid_request")
    filename = body["filename"]
    if (not filename or len(filename.encode()) > 220 or filename in (".", "..") or "/" in filename or "\\" in filename
            or any(unicodedata.category(c).startswith("C") for c in filename)):
        raise Problem("invalid_request")
    if body["role"] not in ROLES or body["mimeType"] not in MIMES or not SHA.fullmatch(body["sha256"]):
        raise Problem("invalid_request")
    if type(body["size"]) is not int:
        raise Problem("invalid_request")
    if not 0 < body["size"] <= settings.max_file:
        raise Problem("file_too_large", 413)
    if body["role"] == "metadata" and (body["mimeType"] != "application/json" or body["size"] > 131072):
        raise Problem("invalid_request")
    try:
        if not re.fullmatch(r"\d{4}/\d{2}/\d{2}", body["datePath"]):
            raise ValueError()
        datetime.strptime(body["datePath"], "%Y/%m/%d")
        datetime.fromisoformat(body["createdAt"].replace("Z", "+00:00"))
    except ValueError:
        raise Problem("invalid_request") from None
    return body


def create_app(settings: Settings, *, google_http=None, drive=None, run_worker=True):
    store = Store(settings)
    authorization = OwnerGoogleAuthorization(store, google_http)
    drive = drive or GoogleDrive(authorization)

    async def loop():
        while True:
            try:
                worked = await worker_once(store, drive)
                store.set("worker_health", "ok")
            except asyncio.CancelledError:
                raise
            except Exception:
                # Never log exception reprs: request URLs and tokens can be included.
                store.set("worker_health", "error")
                worked = False
            await asyncio.sleep(0.25 if worked else 5)

    @asynccontextmanager
    async def lifespan(app):
        task = asyncio.create_task(loop()) if run_worker else None
        try:
            yield
        finally:
            if task:
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass

    app = FastAPI(title="Focal Owner Backup", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    from urllib.parse import urlparse
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=[urlparse(settings.public_url).hostname])
    app.state.store, app.state.authorization, app.state.drive = store, authorization, drive

    @app.middleware("http")
    async def safety_headers(request, call_next):
        if not settings.testing and request.url.scheme != "https":
            return JSONResponse({"error": "https_required"}, status_code=400)
        try:
            response = await call_next(request)
        except Problem as problem:
            response = JSONResponse({"error": problem.code}, status_code=problem.status)
        except Exception:
            response = JSONResponse({"error": "internal_error"}, status_code=500)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'"
        return response

    @app.exception_handler(Problem)
    async def problem_handler(request, error):
        return JSONResponse({"error": error.code}, status_code=error.status)

    @app.exception_handler(GoogleFailure)
    async def google_handler(request, error):
        return JSONResponse({"error": "owner_authorization" if error.code == "owner_authorization" else "google_unavailable"}, status_code=503)

    def device(request):
        header = request.headers.get("authorization", "")
        if not header.startswith("Bearer "):
            raise Problem("unauthorized", 401)
        result = store.authenticate(header[7:])
        if request.headers.get("x-focal-destination") != store.destination:
            raise Problem("destination_mismatch", 409)
        store.throttle("device:" + result["id"], 240)
        return result

    @app.get("/health")
    async def health():
        return {"ok": True}

    @app.post("/v1/enroll")
    async def enroll(request: Request):
        # Only a digest of IP enters the bounded abuse counter, not access logs.
        store.throttle("enroll:" + digest(request.client.host if request.client else "unknown"), 20)
        body = await object_body(request)
        code = body.get("code")
        if not isinstance(code, str) or not 16 <= len(code) <= 256:
            raise Problem("invalid_invitation", 401)
        return store.redeem(code)

    @app.get("/v1/status")
    async def status(request: Request):
        grant = device(request)
        return {"destinationId": store.destination, "deviceId": grant["id"], "ownerLabel": settings.owner_label,
                "driveConnected": authorization.connected}

    @app.post("/v1/resources")
    async def reserve(request: Request):
        grant = device(request)
        value = validate_resource(await object_body(request), settings)
        if value["destinationId"] != store.destination:
            raise Problem("destination_mismatch", 409)
        return store.response(store.reserve(grant["id"], value))

    @app.get("/v1/resources/{resource_id}")
    async def resource(resource_id: str, request: Request):
        grant = device(request)
        if not ID.fullmatch(resource_id):
            raise Problem("invalid_request")
        return store.response(store.resource(grant["id"], resource_id))

    @app.put("/v1/resources/{resource_id}/data")
    async def append(resource_id: str, request: Request):
        grant = device(request)
        if not ID.fullmatch(resource_id):
            raise Problem("invalid_request")
        header = request.headers.get("content-range", "")
        match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", header)
        if not match:
            raise Problem("invalid_range")
        start, end, total = map(int, match.groups())
        if end < start or end - start + 1 > 4 * 1024**2 or end >= total:
            raise Problem("invalid_range")
        body = await bounded_body(request, 4 * 1024**2)
        if len(body) != end - start + 1:
            raise Problem("invalid_range")
        # Serialization + fsync + FULL SQLite commit precede acknowledging offset.
        from starlette.concurrency import run_in_threadpool
        row = await run_in_threadpool(store.append, grant["id"], resource_id, start, total, body)
        return store.response(row)

    @app.post("/v1/resources/{resource_id}/retry")
    async def retry(resource_id: str, request: Request):
        grant = device(request)
        if not ID.fullmatch(resource_id):
            raise Problem("invalid_request")
        store.retry(grant["id"], resource_id)
        return {"ok": True}

    @app.get("/admin", response_class=HTMLResponse)
    async def admin():
        return """<!doctype html><title>Focal owner authorization</title><meta name=referrer content=no-referrer>
            <h1>Focal owner authorization</h1><p>This page is for the backup owner, not testers.</p>
            <form method=post action=/admin/google/start><label>Owner admin token
            <input name=admin_token type=password required autocomplete=off></label>
            <button>Authorize owner Google Drive</button></form>"""

    @app.post("/admin/google/start")
    async def google_start(request: Request):
        store.throttle("admin-start", 10)
        if request.headers.get("origin") != settings.public_url:
            raise Problem("invalid_origin", 403)
        from urllib.parse import parse_qs
        form = parse_qs((await bounded_body(request, 2048)).decode("utf-8", "strict"))
        supplied = form.get("admin_token", [""])[0]
        if not hmac.compare_digest(supplied.encode(), settings.admin_token.encode()):
            raise Problem("unauthorized", 401)
        url, cookie = authorization.begin()
        response = RedirectResponse(url, status_code=303)
        response.set_cookie("focal_owner_oauth", cookie, max_age=600, secure=True, httponly=True, samesite="lax", path="/admin")
        return response

    @app.get("/admin/google/callback")
    async def google_callback(request: Request):
        await authorization.complete(request.query_params.get("code", ""), request.query_params.get("state", ""), request.cookies.get("focal_owner_oauth", ""))
        response = RedirectResponse("/admin/connected", status_code=303)
        response.delete_cookie("focal_owner_oauth", path="/admin", secure=True, httponly=True, samesite="lax")
        return response

    @app.get("/admin/connected", response_class=HTMLResponse)
    async def connected():
        return "<h1>Authorization processed</h1><p>Use the owner CLI to check status and create a device invitation.</p>"

    return app


def app_factory():
    return create_app(Settings.from_env())
