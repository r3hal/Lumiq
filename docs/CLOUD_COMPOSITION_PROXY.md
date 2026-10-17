# Production Cloud Composition proxy architecture

The current Gemini adapter is a local developer prototype. No backend is deployed, no authentication system is added to Focal, and no Google Drive code is changed. A production build must not contain a shared Gemini key. The CloudCompositionService boundary is the adapter seam; the current Release service factory intentionally has no developer credentials.

## Minimal contract and flow

Client -> authenticated HTTPS POST /v1/composition-scans -> bounded in-memory JPEG validation -> server-selected Gemini model -> strict JSON validation -> CloudCompositionResult -> independent local camera verification.

The endpoint accepts exactly one JPEG (at most 160 KiB, at most 768 pixels on the long edge) plus bounded local composition facts and an idempotency request ID. Do not accept remote image URLs, files, video streams or arbitrary provider request bodies. Return only the validated composition result, a model/version identifier and request ID; never return provider credentials or raw provider errors.

Use the app's authenticated user/session provider with short-lived access tokens. Verify signature, issuer, audience, expiry and authorization on the server using the provider's maintained verification library. Do not treat a client-provided user ID, app API key or decoded-but-unverified JWT as authentication. Focal currently has no such login/proxy integration; that is required production work, not a hidden dependency already implemented here.

## Quota and abuse controls

- Limit one active scan per authenticated user; enforce atomic server-side token buckets and a daily budget. An initial configurable example is two scans/minute and twenty/day per user, subject to the actual provider/project allowance.
- Apply a global project request/token/cost ceiling and circuit breaker below the Google quota. Return 429 with bounded retry guidance when exhausted. Do not retry image requests automatically after uncertain delivery.
- Rate-limit failed authentication and apply bounded IP/device controls. Prefer privacy-conscious, short-lived counters over retaining raw IP histories. If App Attest/App Check is adopted, validate its tokens/nonces server-side and treat it as an additional signal, not user authorization.
- Enforce body/content-length limits before buffering, decoded pixel/decompression limits, JPEG magic/MIME checks and strict schema/range limits. Re-encode sanitized pixels to remove metadata. Reject request IDs replayed for a different body without storing that body.
- Keep the model allowlist, schema, prompt, timeouts, concurrency and maximum output on the server. The client must not select arbitrary paid models, tools or destinations.

## Secrets and retention

Store the provider credential in a managed server secret store with a scoped service identity and rotation procedure. Use the x-goog-api-key header only over HTTPS to the fixed Google origin; refuse redirects. Never include secrets in URLs, client bundles, exception text, traces or artifacts. Restrict outbound destinations. Store no uploaded images, thumbnails, prompts, free-form model text or provider error bodies in databases, object storage, queues or logs. Disable request/response body logging at the load balancer, gateway, framework, observability and error-reporting layers. Use only bounded in-memory processing; clear request references after completion/cancellation.

Maintain minimal aggregate operational counts, latency/error classes and quota counters. Request hashes/idempotency metadata need short TTLs and should not become an image-reidentification store. Provider-side processing/retention remains governed by the selected Google service/account/region; the proxy cannot promise deletion from Google. Do not use Google's Files API for this one-still flow.

The client must retain all local validation, session guards, privacy disclosure and user-only shutter behavior. Backend success does not set READY or authorize a camera command. Test authentication, replay, per-user/global quotas, oversized/malformed payloads, provider timeout/cancellation, log redaction and no image retention before rollout. Distribute only a build wired to the reviewed proxy/authentication adapter, never the developer-key Debug build.

[Google key-security guidance](https://ai.google.dev/gemini-api/docs/api-key), [Google data terms](https://ai.google.dev/gemini-api/terms).
