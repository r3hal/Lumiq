# Lumiq AI server (free)

A small Cloudflare Worker that powers **AI Shot**, Lumiq's one-tap shot finder. The app sends one compressed frame (≤768 px). The server answers with:

```json
{ "subject": "bed texture and garments",
  "tip": "Isolate the textures. Focus on the details.",
  "technique": "detail",
  "frame": { "x": 0.31, "y": 0.42, "width": 0.4, "height": 0.4 },
  "zoom": 2.5, "provider": "gemini" }
```

`frame` is the part of the current view that should become the photo. The iPhone tracks it on-device, guides you to center it, zooms in and shows **Ready**.

Everything here runs on free tiers. The server tries these providers in order:

| Provider | Needs | Notes |
|---|---|---|
| Google Gemini (`gemini-flash-latest`, then Gemma 4 and `gemini-flash-lite-latest` when busy) | free key from [aistudio.google.com/apikey](https://aistudio.google.com/apikey) | Best framing quality |
| Groq (`llama-4-scout`) | free key from [console.groq.com/keys](https://console.groq.com/keys) | Very fast; optional |
| Cloudflare Workers AI (`llama-4-scout`) | nothing, it's built in | Always-on fallback (free daily allowance) |

## Deploy in about 5 minutes

1. Create a free Cloudflare account at [dash.cloudflare.com](https://dash.cloudflare.com/sign-up).
2. In this folder, run:
   ```sh
   npm install
   npx wrangler login
   npx wrangler deploy
   ```
   Wrangler prints your URL, for example `https://lumiq-ai.<you>.workers.dev`.
3. Protect the server so only your app can use your free quota:
   ```sh
   npx wrangler secret put APP_TOKEN        # paste any long random string
   npx wrangler secret put GEMINI_API_KEY   # recommended
   npx wrangler secret put GROQ_API_KEY     # optional
   ```
4. On the iPhone, long-press the ✦ button (or open Settings › AI Shot) and enter the URL and the same APP_TOKEN. Tap **Test server**.

Without a terminal, you can also use the dashboard: Workers & Pages › Create › Worker. Paste `src/index.js`, then add an **AI** binding named `AI` under Settings › Bindings, and add the secrets under Settings › Variables.

## No server at all

In Settings › AI Shot you can paste a Gemini key directly. The phone then calls Gemini itself and stores the key in the Keychain. The server is still better: the key stays off the phone, and it falls back to Groq and Workers AI when Gemini's free quota runs out.

## Test

```sh
npm test                                   # parser and crop rules
curl https://lumiq-ai.<you>.workers.dev/health
```

Model names can be changed without code edits (see `wrangler.toml` `[vars]`).
