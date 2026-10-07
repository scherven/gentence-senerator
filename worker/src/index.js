// Watches the app's grading batches and pushes when one ends.
//
// A batch that has not ended DIRECT_AFTER_MS after it was sent is cancelled
// and graded here with ordinary calls instead: batches are half price but can
// sit in a queue for hours. The requests are kept (`req:`) for that; the
// direct results go to `res:` in the batch results-file format, and the app
// asks /results for them before reading a cancelled batch.
//
// One KV key per watched batch, `watch:<id>`. A single shared list was
// read-modify-written by both /watch and the cron, so a batch registered
// while another was being cleared could be dropped and never notify — with
// two languages out at once that is exactly the case that happens.
// The cron runs every two minutes because listing keys is capped at 1,000 a
// day on the free tier.
//
// The app holds no keys. It sends an invite code (`x-invite`), minted with
// invite.sh into `invite:<code>`; the worker adds the Anthropic and Azure
// keys and forwards. Deleting the KV key revokes the code within a minute.

const WATCH = "watch:";
// The batch a job became, so a resent job returns it instead of paying twice.
const JOB = "job:";
const APNS_JWT = "apns-jwt";
// A batch's requests, kept so it can be graded directly if it stalls.
const REQ = "req:";
// Direct results, JSONL like a batch results file, or {"pending":true}.
const RES = "res:";
// The app shows a countdown to this, from when it sent the batch.
const DIRECT_AFTER_MS = 20 * 60 * 1000;
// A batch that has not ended in this long has expired on Anthropic's side
// (24h) and will never end here either.
const GIVE_UP_MS = 26 * 3600 * 1000;
const INVITE = "invite:";
// The only model the app uses, and its largest max_tokens: anything else
// through the proxy is someone else's traffic.
const MODEL = "claude-opus-5";
const MAX_TOKENS = 32000;
const BETA = "server-side-fallback-2026-07-01";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      const { keys } = await env.STATE.list({ prefix: WATCH });
      return Response.json({ watching: keys.length });
    }
    const who = await admit(request, env);
    if (who instanceof Response) return who;
    console.log(`${who.name} ${request.method} ${url.pathname}`);

    if (request.method === "GET" && url.pathname === "/check") {
      return Response.json({ name: who.name });
    }
    if (url.pathname.startsWith("/anthropic/")) return anthropic(request, env, url);
    if (request.method === "POST" && url.pathname === "/azure/pronounce") {
      return azure(request, env, url);
    }
    // The app's background upload lands here: create the batch and watch it
    // in one step, so a batch can never exist without being watched. The
    // phone's upload can be retried by iOS at any point, so the job id makes
    // it idempotent.
    if (request.method === "POST" && url.pathname === "/submit") {
      const job = request.headers.get("x-job-id");
      if (!job) return new Response("x-job-id", { status: 400 });
      const token = request.headers.get("x-token") || null;
      const label = request.headers.get("x-label") || null;
      const sandbox = request.headers.get("x-sandbox") !== "0";

      const existing = await env.STATE.get(JOB + job);
      if (existing) return Response.json({ batch: existing, resent: true });

      const body = await request.text();
      const bad = (JSON.parse(body).requests || []).find((r) => !allowed(r.params));
      if (bad) return new Response("model or max_tokens", { status: 403 });
      const created = await fetch("https://api.anthropic.com/v1/messages/batches", {
        method: "POST",
        headers: {
          "x-api-key": env.ANTHROPIC_KEY.trim(),
          "anthropic-version": "2023-06-01",
          "content-type": "application/json",
        },
        body,
      });
      const text = await created.text();
      if (!created.ok) return new Response(text, { status: created.status });
      const batch = JSON.parse(text).id;

      await env.STATE.put(JOB + job, batch, { expirationTtl: 3 * 24 * 3600 });
      await env.STATE.put(REQ + batch, body, { expirationTtl: 2 * 24 * 3600 });
      if (token) {
        await env.STATE.put(WATCH + batch,
          JSON.stringify({ batch, token, label, sandbox, job, since: Date.now() }),
          { expirationTtl: GIVE_UP_MS / 1000 });
      }
      return Response.json({ batch, watched: !!token });
    }
    if (request.method === "POST" && url.pathname === "/watch") {
      // `label` names the session in the push — "Mandarin produce" — since two
      // languages can be out at once and "1 graded" alone says neither.
      // `job` is optional: the app's late /watch doesn't send it, and the push
      // falls back to the batch id.
      const { batch, token, label, sandbox, job } = await request.json();
      if (!batch || !token) return new Response("batch and token", { status: 400 });
      await env.STATE.put(WATCH + batch,
                          JSON.stringify({ batch, token, label, sandbox: sandbox !== false,
                                           job: job || null, since: Date.now() }),
                          { expirationTtl: GIVE_UP_MS / 1000 });
      return Response.json({ watching: batch });
    }
    // What the worker graded directly for a batch: 404 if it didn't step in,
    // 202 while it is grading, else the results file.
    if (request.method === "GET" && url.pathname === "/results") {
      const batch = url.searchParams.get("batch");
      if (!batch) return new Response("batch", { status: 400 });
      const stored = await env.STATE.get(RES + batch);
      if (!stored) return new Response("none", { status: 404 });
      if (stored.startsWith('{"pending"')) return new Response("grading", { status: 202 });
      return new Response(stored, { headers: { "content-type": "application/x-ndjson" } });
    }
    return new Response("not found", { status: 404 });
  },

  async scheduled(_event, env, ctx) {
    ctx.waitUntil(poll(env));
  },
};

// The invite on the request, or the response refusing it.
async function admit(request, env) {
  const code = request.headers.get("x-invite")?.trim().toUpperCase();
  if (!code) return new Response("invite", { status: 401 });
  const invite = await env.STATE.get(INVITE + code, { type: "json", cacheTtl: 60 });
  if (!invite) return new Response("invite", { status: 401 });
  const { success } = await env.PER_INVITE.limit({ key: code });
  if (!success) return new Response("slow down", { status: 429 });
  return { code, name: invite.name || code };
}

function allowed(params) {
  return params && params.model === MODEL
    && Number.isInteger(params.max_tokens) && params.max_tokens <= MAX_TOKENS;
}

// /anthropic/v1/<path>: one message, or reading a batch the app was handed.
async function anthropic(request, env, url) {
  const path = url.pathname.slice("/anthropic".length);
  const message = request.method === "POST" && path === "/v1/messages";
  const batch = request.method === "GET"
    && /^\/v1\/messages\/batches\/[A-Za-z0-9_]+(\/results)?$/.test(path);
  if (!message && !batch) return new Response("not found", { status: 404 });

  const headers = { "x-api-key": env.ANTHROPIC_KEY.trim(), "anthropic-version": "2023-06-01" };
  let body;
  if (message) {
    body = await request.text();
    let params;
    try { params = JSON.parse(body); } catch { return new Response("json", { status: 400 }); }
    if (!allowed(params)) return new Response("model or max_tokens", { status: 403 });
    headers["content-type"] = "application/json";
    headers["anthropic-beta"] = BETA;
  }
  const r = await fetch(`https://api.anthropic.com${path}`, { method: request.method, headers, body });
  return new Response(r.body, {
    status: r.status,
    headers: { "content-type": r.headers.get("content-type") || "application/json" },
  });
}

async function azure(request, env, url) {
  const target = new URL(
    `https://${env.AZURE_REGION}.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1`);
  for (const name of ["language", "format"]) {
    const value = url.searchParams.get(name);
    if (value) target.searchParams.set(name, value);
  }
  const r = await fetch(target, {
    method: "POST",
    headers: {
      "Ocp-Apim-Subscription-Key": env.AZURE_KEY.trim(),
      "content-type": request.headers.get("content-type") || "audio/wav",
      "pronunciation-assessment": request.headers.get("pronunciation-assessment") || "",
    },
    body: request.body,
  });
  return new Response(r.body, {
    status: r.status,
    headers: { "content-type": r.headers.get("content-type") || "application/json" },
  });
}

async function poll(env) {
  const { keys } = await env.STATE.list({ prefix: WATCH });
  for (const { name } of keys) {
    // Listing can lag a delete; a key already gone was already pushed.
    const w = await env.STATE.get(name, "json");
    if (!w) continue;
    if (w.direct) continue; // being graded directly by an earlier run
    const batch = await retrieve(env, w.batch);
    if (!batch) continue;
    if (batch.processing_status === "ended") {
      await env.STATE.delete(name);
      await push(env, w, countsOf(batch), batch.id);
      continue;
    }
    if (Date.now() - w.since < DIRECT_AFTER_MS) continue;
    const body = await env.STATE.get(REQ + w.batch);
    if (!body) continue; // sent before requests were kept: wait it out
    await gradeDirectly(env, name, w, JSON.parse(body).requests);
  }
}

// Claims the watch, cancels the batch, grades every request with an ordinary
// call, stores the results and pushes. A failed call is stored as an error,
// which the app retries once on its own, as it does for a batch.
async function gradeDirectly(env, name, w, requests) {
  await env.STATE.put(name, JSON.stringify({ ...w, direct: true }),
                      { expirationTtl: GIVE_UP_MS / 1000 });
  await env.STATE.put(RES + w.batch, '{"pending":true}', { expirationTtl: 3 * 24 * 3600 });
  await fetch(`https://api.anthropic.com/v1/messages/batches/${w.batch}/cancel`, {
    method: "POST",
    headers: { "x-api-key": env.ANTHROPIC_KEY.trim(), "anthropic-version": "2023-06-01" },
  });

  const lines = await Promise.all(requests.map(async ({ custom_id, params }) => {
    try {
      const r = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "x-api-key": env.ANTHROPIC_KEY.trim(),
          "anthropic-version": "2023-06-01",
          "anthropic-beta": "server-side-fallback-2026-07-01",
          "content-type": "application/json",
        },
        // Unlike a batch, a direct call may route around a refusal.
        body: JSON.stringify({ ...params, fallbacks: "default" }),
      });
      const text = await r.text();
      if (!r.ok) return { custom_id, result: { type: "errored", error: { error: { message: text.slice(0, 300) } } } };
      return { custom_id, result: { type: "succeeded", message: JSON.parse(text) } };
    } catch (e) {
      return { custom_id, result: { type: "errored", error: { error: { message: String(e) } } } };
    }
  }));

  await env.STATE.put(RES + w.batch, lines.map((l) => JSON.stringify(l)).join("\n"),
                      { expirationTtl: 3 * 24 * 3600 });
  await env.STATE.delete(name);
  const succeeded = lines.filter((l) => l.result.type === "succeeded").length;
  await push(env, w, { succeeded, failed: lines.length - succeeded }, w.batch);
}

function countsOf(batch) {
  const c = batch.request_counts;
  return { succeeded: c.succeeded, failed: c.errored + c.expired + c.canceled };
}

async function retrieve(env, id) {
  const response = await fetch(`https://api.anthropic.com/v1/messages/batches/${id}`, {
    headers: { "x-api-key": env.ANTHROPIC_KEY.trim(), "anthropic-version": "2023-06-01" },
  });
  if (!response.ok) {
    console.log(`batch ${id}: ${response.status} ${await response.text()}`);
    return null;
  }
  return response.json();
}

async function push(env, w, counts, batchID) {
  const { token, label } = w;
  const graded = counts.succeeded;
  const failed = counts.failed;
  const count = failed === 0 ? `${graded} graded.` : `${graded} graded, ${failed} failed.`;
  const body = label ? `${label}: ${count}` : count;

  // Xcode builds can only hear the sandbox; TestFlight and App Store builds
  // only production. The app says which it is.
  const host = w.sandbox === false ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const response = await fetch(`https://${host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await providerToken(env)}`,
      "apns-topic": env.APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
    },
    body: JSON.stringify({
      aps: { alert: { title: "Feedback ready", body }, sound: "default" },
      // What a tap opens. Watches stored before job ids were kept have only
      // the batch, which the app matches too.
      batch: batchID,
      ...(w.job ? { job: w.job } : {}),
    }),
  });
  // A bad token is logged and dropped; retrying would only fail again.
  if (!response.ok) console.log(`push ${batchID}: ${response.status} ${await response.text()}`);
}

// APNs rejects a provider token regenerated more often than every 20 minutes
// and one older than an hour, so it is kept for 50.
async function providerToken(env) {
  const cached = await env.STATE.get(APNS_JWT, "json");
  const now = Math.floor(Date.now() / 1000);
  if (cached && now - cached.iat < 50 * 60) return cached.jwt;

  const header = { alg: "ES256", kid: env.APNS_KEY_ID };
  const claims = { iss: env.APNS_TEAM_ID, iat: now };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;

  const der = Uint8Array.from(
    atob(env.APNS_KEY.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")),
    (ch) => ch.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
  // WebCrypto returns r||s, which is already the JWS encoding.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput),
  );
  const jwt = `${signingInput}.${b64url(signature)}`;
  await env.STATE.put(APNS_JWT, JSON.stringify({ jwt, iat: now }));
  return jwt;
}

function b64url(input) {
  const bytes = typeof input === "string"
    ? new TextEncoder().encode(input)
    : new Uint8Array(input);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
