import { test } from "node:test";
import assert from "node:assert/strict";
import { normalize, parseJSON, validateInput } from "../src/index.js";

const input = { aspect: 0.75, zoom: 1, minZoom: 0.5, maxZoom: 6 };

test("square-normalized crop, zoom derived from crop size", () => {
  const r = normalize({ subject: "Bed Texture", tip: "Isolate the textures.", technique: "detail", box_2d: [400, 300, 700, 600], confidence: 0.9 }, input);
  assert.equal(r.subject, "bed texture");
  assert.equal(r.frame.width, 0.3);
  assert.equal(r.frame.height, 0.3);
  assert.equal(r.frame.x, 0.3);
  assert.equal(r.frame.y, 0.4);
  assert.equal(r.zoom, 3.33);
});

test("crop is limited by max zoom and kept inside the view", () => {
  const r = normalize({ box_2d: [950, 950, 1000, 1000] }, input);
  assert.ok(r.frame.width >= 1 / 6 - 1e-9);
  assert.ok(r.frame.x + r.frame.width <= 1 + 1e-9 && r.frame.y + r.frame.height <= 1 + 1e-9);
  assert.equal(r.zoom, 6);
});

test("almost-full crops become the whole frame", () => {
  const r = normalize({ box_2d: [0.02, 0.03, 0.97, 0.95] }, input);
  assert.deepEqual(r.frame, { x: 0, y: 0, width: 1, height: 1 });
  assert.equal(r.zoom, 1);
});

test("rejects garbage", () => {
  assert.equal(normalize({ box_2d: [1, 2] }, input), null);
  assert.equal(normalize("no json here", input), null);
  assert.equal(validateInput({ image: "x" }), null);
});

test("parses fenced model output", () => {
  assert.deepEqual(parseJSON('```json\n{"a":1}\n```'), { a: 1 });
});
