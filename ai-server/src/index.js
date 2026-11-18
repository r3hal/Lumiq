// Lumiq AI Shot server — a free Cloudflare Worker.
//
// POST /v1/shot  { image: <base64 JPEG>, aspect: <width/height of viewfinder>,
//                  zoom, minZoom, maxZoom }
// -> { subject, tip, technique, frame: {x,y,width,height}, zoom, provider }
//
// `frame` is the region of the CURRENT view that should become the final photo
// (normalized, top-left origin). The app tracks it, guides the user to center
// it, zooms so it fills the viewfinder and then shows "Ready".
//
// Providers are tried in order. All have free tiers:
//   1. Google Gemini        (secret GEMINI_API_KEY)  best quality
//   2. Groq                 (secret GROQ_API_KEY)    very fast
//   3. Cloudflare Workers AI (no key, the [ai] binding) always-available fallback

const TECHNIQUES = ["rule of thirds", "centered", "leading lines", "symmetry", "negative space", "framing", "fill the frame", "layers", "detail"];

const PROMPT = `You are a world-class photographer standing behind someone holding a phone camera.
Look at this live camera view and pick the single most beautiful photo that can be taken from it RIGHT NOW by only pointing the camera and zooming in (no moving the feet).
Prefer a clear subject with a clean composition: crop out clutter, empty floor, cut-off objects and distracting edges. A tighter, intentional crop usually beats the full view. If the full view is already the best photo, return the whole frame.

Return JSON only:
{
  "subject": short lowercase description of what the photo is about, 2-5 words (e.g. "bed texture and garments", "woman by the window", "door and light"),
  "tip": one short photographer instruction, max 9 words, imperative (e.g. "Isolate the textures. Focus on the details."),
  "technique": one of ${JSON.stringify(TECHNIQUES)},
  "box_2d": [ymin, xmin, ymax, xmax] of the ideal photo crop in this image, integers 0-1000,
  "confidence": 0-1
}
The crop should roughly match a portrait ASPECT_HINT shape and keep the subject well placed (rule of thirds or centered).`;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, providers: providers(env).map((p) => p.name) });
    }
    if (request.method !== "POST" || url.pathname !== "/v1/shot") return json({ error: "not_found" }, 404);
    if (env.APP_TOKEN && request.headers.get("Authorization") !== `Bearer ${env.APP_TOKEN}`) {
      return json({ error: "unauthorized" }, 401);
    }
    const length = Number(request.headers.get("Content-Length") || 0);
    if (length > 600_000) return json({ error: "too_large" }, 413);

    let body;
    try { body = await request.json(); } catch { return json({ error: "bad_json" }, 400); }
    const input = validateInput(body);
    if (!input) return json({ error: "bad_request" }, 400);

    const errors = [];
    for (const provider of providers(env)) {
      try {
        const raw = await withTimeout(provider.run(input, env), 18_000);
        const result = normalize(raw, input);
        if (result) return json({ ...result, provider: provider.name });
        errors.push(`${provider.name}:invalid`);
      } catch (error) {
        errors.push(`${provider.name}:${String(error && error.message || error).slice(0, 80)}`);
      }
    }
    return json({ error: "all_providers_failed", detail: errors }, 502);
  },
};

// ---------------------------------------------------------------- input / output

export function validateInput(body) {
  if (!body || typeof body.image !== "string" || body.image.length < 100 || body.image.length > 560_000) return null;
  if (!/^[A-Za-z0-9+/=]+$/.test(body.image.slice(0, 64))) return null;
  const num = (v, d, lo, hi) => (Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : d);
  const zoom = num(body.zoom, 1, 0.5, 20);
  const minZoom = num(body.minZoom, Math.min(1, zoom), 0.5, zoom);
  const maxZoom = num(body.maxZoom, 6, zoom, 20);
  return { image: body.image, aspect: num(body.aspect, 0.75, 0.3, 3), zoom, minZoom, maxZoom };
}

function cleanText(value, max, fallback) {
  if (typeof value !== "string") return fallback;
  const text = value.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
  if (!text) return fallback;
  return text.length > max ? text.slice(0, max - 1).trimEnd() + "…" : text;
}

/** Parses model output into a validated, achievable shot. */
export function normalize(raw, input) {
  const data = typeof raw === "string" ? parseJSON(raw) : raw;
  if (!data || typeof data !== "object") return null;
  let box = data.box_2d || data.box || data.crop;
  if (!Array.isArray(box) || box.length !== 4 || !box.every(Number.isFinite)) return null;
  // Accept 0-1 or 0-1000 coordinates.
  const scale = Math.max(...box) <= 1.0001 ? 1 : 1000;
  let [ymin, xmin, ymax, xmax] = box.map((v) => Math.min(1, Math.max(0, v / scale)));
  if (xmax < xmin) [xmin, xmax] = [xmax, xmin];
  if (ymax < ymin) [ymin, ymax] = [ymax, ymin];
  if (xmax - xmin < 0.02 || ymax - ymin < 0.02) return null;

  // The view is normalized 0-1 on both axes but is `aspect` wide per 1 tall.
  // Fit the crop to the viewfinder shape so it can fill the screen after zoom.
  const cx = (xmin + xmax) / 2, cy = (ymin + ymax) / 2;
  let w = xmax - xmin, h = ymax - ymin; // normalized
  // Same shape as the screen means w == h in normalized units. Cover the model box.
  let size = Math.max(w, h);
  // Achievable zoom: size = currentZoom / targetZoom.
  const minSize = input.zoom / input.maxZoom;
  size = Math.min(1, Math.max(size, minSize, 0.12));
  if (size > 0.9) size = 1; // Not worth a tiny zoom; keep the full view.
  let x = Math.min(1 - size, Math.max(0, cx - size / 2));
  let y = Math.min(1 - size, Math.max(0, cy - size / 2));
  const zoom = round(Math.min(input.maxZoom, Math.max(input.zoom, input.zoom / size)), 2);

  const technique = TECHNIQUES.includes(String(data.technique).toLowerCase()) ? String(data.technique).toLowerCase() : "rule of thirds";
  const confidence = Number.isFinite(data.confidence) ? Math.min(1, Math.max(0, data.confidence)) : 0.7;
  return {
    subject: cleanText(data.subject, 48, "your shot").toLowerCase(),
    tip: cleanText(data.tip, 80, "Center the frame and hold steady."),
    technique,
    confidence: round(confidence, 2),
    frame: { x: round(x, 4), y: round(y, 4), width: round(size, 4), height: round(size, 4) },
    zoom,
  };
}

export function parseJSON(text) {
  if (typeof text !== "string") return null;
  const start = text.indexOf("{"), end = text.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try { return JSON.parse(text.slice(start, end + 1)); } catch { return null; }
}

function promptFor(input) {
  const shape = input.aspect < 0.95 ? `${Math.round(input.aspect * 100) / 100}:1 (portrait)` : `${Math.round(input.aspect * 100) / 100}:1`;
  return PROMPT.replace("portrait ASPECT_HINT", shape) +
    `\nCurrent zoom ${input.zoom}x; you may zoom in at most ${round(input.maxZoom / input.zoom, 1)}x more, so the crop must be at least ${Math.round(100 * input.zoom / input.maxZoom)}% of the image width.`;
}

// ---------------------------------------------------------------- providers

function providers(env) {
  const list = [];
  if (env.GEMINI_API_KEY) list.push({ name: "gemini", run: gemini });
  if (env.GROQ_API_KEY) list.push({ name: "groq", run: groq });
  if (env.AI) list.push({ name: "workers-ai", run: workersAI });
  return list;
}

async function gemini(input, env) {
  const models = (env.GEMINI_MODELS || "gemini-flash-latest,gemma-4-26b-a4b-it,gemini-flash-lite-latest").split(",").map((m) => m.trim()).filter(Boolean);
  let last;
  for (const model of models) {
    const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
      method: "POST",
      redirect: "error",
      headers: { "Content-Type": "application/json", "x-goog-api-key": env.GEMINI_API_KEY },
      body: JSON.stringify({
        contents: [{ role: "user", parts: [{ text: promptFor(input) }, { inlineData: { mimeType: "image/jpeg", data: input.image } }] }],
        generationConfig: {
          // No thinkingConfig: current models reject thinkingBudget = 0 with HTTP 400.
          temperature: 0.3, maxOutputTokens: 2048, responseMimeType: "application/json",
        },
      }),
    });
    if (!response.ok) { last = new Error(`gemini ${model} ${response.status}`); continue; }
    const data = await response.json();
    const text = (data.candidates?.[0]?.content?.parts || []).filter((p) => !p.thought && p.text).map((p) => p.text).join("");
    if (text) return text;
    last = new Error(`gemini ${model} empty`);
  }
  throw last || new Error("gemini unavailable");
}

async function groq(input, env) {
  const response = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    redirect: "error",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${env.GROQ_API_KEY}` },
    body: JSON.stringify({
      model: env.GROQ_MODEL || "meta-llama/llama-4-scout-17b-16e-instruct",
      temperature: 0.3, max_completion_tokens: 400,
      response_format: { type: "json_object" },
      messages: [{ role: "user", content: [
        { type: "text", text: promptFor(input) },
        { type: "image_url", image_url: { url: `data:image/jpeg;base64,${input.image}` } },
      ] }],
    }),
  });
  if (!response.ok) throw new Error(`groq ${response.status}`);
  const data = await response.json();
  return data.choices?.[0]?.message?.content;
}

async function workersAI(input, env) {
  const result = await env.AI.run(env.WORKERS_AI_MODEL || "@cf/meta/llama-4-scout-17b-16e-instruct", {
    max_tokens: 400, temperature: 0.3,
    messages: [{ role: "user", content: [
      { type: "text", text: promptFor(input) },
      { type: "image_url", image_url: { url: `data:image/jpeg;base64,${input.image}` } },
    ] }],
  });
  return typeof result?.response === "string" ? result.response : result?.response ?? result;
}

// ---------------------------------------------------------------- helpers

function round(v, digits) { const f = 10 ** digits; return Math.round(v * f) / f; }

function withTimeout(promise, ms) {
  return Promise.race([promise, new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), ms))]);
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}
