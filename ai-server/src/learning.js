// AI Shot learning: anonymous shot results in, learned prompt guidance out.
//
// POST /v1/feedback  one shot result (no image, no personal data):
//   { session, model, technique, subject, aiZoom, startZoom, crop, aspect,
//     outcome: "taken" | "new_shot" | "cancelled" | "lost",
//     reachedReady, secondsToReady, userZoom, app }
// GET  /v1/guidance  -> { samples, guidance: ["…", …] }
//   Short rules learned from everyone's results, which the app adds to the
//   instructions it gives the AI. Rules appear only once there is enough data.

export const OUTCOMES = ["taken", "new_shot", "cancelled", "lost"];
export const TECHNIQUES = ["rule of thirds", "centered", "leading lines", "symmetry", "negative space", "framing", "fill the frame", "layers", "detail"];

const MIN_SAMPLES = 20;
const MIN_PER_GROUP = 8;
const MAX_RULES = 5;

const STOPWORDS = new Set(["a", "an", "the", "and", "of", "on", "in", "with", "by", "at", "to", "for", "from", "its", "his", "her", "their", "view", "shot", "photo", "scene"]);

function text(value, max) {
  if (typeof value !== "string") return "";
  return value.replace(/[^\p{L}\p{N} .,'-]/gu, " ").replace(/\s+/g, " ").trim().toLowerCase().slice(0, max);
}

function number(value, lo, hi) {
  return typeof value === "number" && Number.isFinite(value) && value >= lo && value <= hi ? value : null;
}

/** Validates one shot result; returns the row to store or null. */
export function validateFeedback(body) {
  if (!body || typeof body !== "object") return null;
  if (typeof body.session !== "string" || !/^[A-Za-z0-9-]{8,40}$/.test(body.session)) return null;
  if (!OUTCOMES.includes(body.outcome)) return null;
  const technique = TECHNIQUES.includes(body.technique) ? body.technique : "";
  const aiZoom = number(body.aiZoom, 0.3, 20);
  if (aiZoom === null) return null;
  return {
    session: body.session,
    model: text(body.model, 40),
    technique,
    subject: text(body.subject, 60),
    ai_zoom: aiZoom,
    start_zoom: number(body.startZoom, 0.3, 20),
    crop: number(body.crop, 0, 1),
    aspect: number(body.aspect, 0.2, 5),
    outcome: body.outcome,
    reached_ready: body.reachedReady === true ? 1 : 0,
    seconds_to_ready: number(body.secondsToReady, 0, 600),
    user_zoom: number(body.userZoom, 0.3, 20),
    app: text(body.app, 24),
  };
}

const median = (values) => {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
};

/**
 * Learns short prompt rules from stored results. "Taken" counts as a good pick; "new_shot" and
 * "cancelled" as bad picks ("lost" says nothing about the pick). Rates are smoothed so a few
 * results cannot produce a rule.
 */
export function buildGuidance(rows) {
  const judged = rows.filter((r) => r.outcome !== "lost");
  if (judged.length < MIN_SAMPLES) return { samples: judged.length, guidance: [] };
  const good = (r) => r.outcome === "taken";
  const overall = judged.filter(good).length / judged.length;
  const smoothed = (list) => (list.filter(good).length + 2 * overall) / (list.length + 2);
  const rules = [];

  // 1. Zoom: do people end up tighter or wider than the AI's suggestion?
  const ratios = judged.filter((r) => good(r) && r.user_zoom && r.ai_zoom).map((r) => r.user_zoom / r.ai_zoom);
  if (ratios.length >= 12) {
    const m = median(ratios);
    if (m > 1.15) rules.push(`People usually zoom in further than suggested (about ${m.toFixed(1)}×): choose tighter crops.`);
    else if (m < 0.87) rules.push(`People usually zoom out from the suggestion: choose wider crops with more context.`);
  }

  // 2. Techniques that are taken or skipped clearly more often than average.
  const techniques = [];
  for (const technique of TECHNIQUES) {
    const list = judged.filter((r) => r.technique === technique);
    if (list.length < MIN_PER_GROUP) continue;
    techniques.push({ technique, rate: smoothed(list), n: list.length });
  }
  for (const t of techniques.sort((a, b) => b.rate - a.rate)) {
    if (t.rate >= overall + 0.15) rules.push(`"${t.technique}" picks are usually taken; prefer them when they fit.`);
    else if (t.rate <= overall - 0.15) rules.push(`"${t.technique}" picks are often skipped; use them only when clearly best.`);
  }

  // 3. Subjects people take or skip.
  const words = new Map();
  for (const r of judged) {
    for (const word of new Set(String(r.subject || "").split(" "))) {
      if (word.length < 3 || STOPWORDS.has(word)) continue;
      const entry = words.get(word) || [];
      entry.push(r);
      words.set(word, entry);
    }
  }
  const subjects = [...words.entries()]
    .filter(([, list]) => list.length >= MIN_PER_GROUP)
    .map(([word, list]) => ({ word, rate: smoothed(list) }))
    .sort((a, b) => Math.abs(b.rate - overall) - Math.abs(a.rate - overall));
  const liked = subjects.filter((s) => s.rate >= overall + 0.2).slice(0, 3).map((s) => s.word);
  const skipped = subjects.filter((s) => s.rate <= overall - 0.2).slice(0, 3).map((s) => s.word);
  if (liked.length) rules.push(`Picks featuring ${liked.join(", ")} are usually taken.`);
  if (skipped.length) rules.push(`Picks featuring ${skipped.join(", ")} are often skipped; look for a stronger subject.`);

  return { samples: judged.length, guidance: rules.slice(0, MAX_RULES) };
}
