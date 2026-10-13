// Watches the app's grading batches and pushes when one ends.
//
// A batch that has not ended DIRECT_AFTER_MS after it was sent is cancelled
// and graded here with ordinary calls instead: batches are half price but can
// sit in a queue for hours. The requests are kept (`req:`) for that; the
// direct results go to `res:` in the batch results-file format, and the app
// asks /results for them before reading a cancelled batch.
//
// One KV key per submitted batch, `watch:<id>`, with a push token or not: the
// direct fallback needs every batch. A single shared list was
// read-modify-written by both /watch and the cron, so a batch registered while
// another was being cleared could be dropped and never notify — with two
// languages out at once that is exactly the case that happens.
// The cron runs every two minutes because listing keys is capped at 1,000 a
// day on the free tier.
//
// The app holds no keys. It sends an invite code (`x-invite`), minted with
// invite.sh into `invite:<code>`; the worker adds the Anthropic and Azure
// keys and forwards. Deleting the KV key revokes the code within a minute.
//
// Spend per code per day, and disputed findings, live in one Durable Object
// (`Ledger`), not KV: the free tier allows 1,000 KV writes a day and has no
// atomic increment, and the Ledger serialises every charge. A code past
// DAILY_CAP_USD for the day is refused until midnight UTC. Batch costs land
// when the batch is collected, so a day can overshoot by its last batch.
// /stats (with ?key=ADMIN_KEY) shows both.

const WATCH = "watch:";
// The batch a job became, so a resent job returns it instead of paying twice;
// {"claim","at"} while a request is making it.
const JOB = "job:";
// A claim older than this belongs to a request that died before its batch.
const CLAIM_MS = 60 * 1000;
const APNS_JWT = "apns-jwt";
// A batch's requests, kept so it can be graded directly if it stalls.
const REQ = "req:";
// Direct results, JSONL like a batch results file, or {"pending":true,"at"}.
const RES = "res:";
// A direct grading not finished in this long died with its run (cron runs
// get 15 minutes); the next poll takes it over, up to TRIES times in all.
const LEASE_MS = 16 * 60 * 1000;
const TRIES = 3;
// The app shows a countdown to this, from when it sent the batch.
const DIRECT_AFTER_MS = 20 * 60 * 1000;
// A batch that has not ended in this long has expired on Anthropic's side
// (24h) and will never end here either.
const GIVE_UP_MS = 26 * 3600 * 1000;
const INVITE = "invite:";
// The models the app uses, each with its largest max_tokens: anything else
// through the proxy is someone else's traffic. Sonnet reviews translate and
// produce answers and writes quiz top-ups.
const MODELS = { "claude-opus-5": 32000, "claude-sonnet-5-5": 32000 };
const BETA = "server-side-fallback-2026-07-01";
// $ per million tokens: input, output, cache read, cache write. Batches half.
const PRICES = {
  "claude-opus-5": [5, 25, 0.5, 6.25],
  "claude-sonnet-5-5": [2, 10, 0.2, 2.5],
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // No KV list here: lists are capped at 1,000 a day and the cron needs 720.
    if (url.pathname === "/health") return Response.json({ ok: true });
    if (request.method === "GET" && url.pathname === "/stats") return stats(env, url);
    const who = await admit(request, env);
    if (who instanceof Response) return who;
    console.log(`${who.name} ${request.method} ${url.pathname}`);

    if (request.method === "GET" && url.pathname === "/check") {
      return Response.json({ name: who.name });
    }
    if (url.pathname.startsWith("/anthropic/")) return anthropic(request, env, url, who);
    // A learner saying a finding is wrong. Kept with who said it, for the eval set.
    if (request.method === "POST" && url.pathname === "/dispute") {
      let given;
      try { given = await request.json(); } catch { return new Response("json", { status: 400 }); }
      if (!given || typeof given !== "object") return new Response("json", { status: 400 });
      await ledger(env, "/dispute", { ...given, code: who.code, name: who.name, at: new Date().toISOString() });
      return Response.json({ ok: true });
    }
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

      // The app sends a job twice on purpose (Send now beside the background
      // upload), so the job is claimed before the batch is made: KV has no
      // compare-and-set, but write, pause, re-read leaves one claim standing.
      // A request that loses waits for the winner's batch, else 409, which
      // the app retries later. The body is read first so nothing slow sits
      // between the check and the claim. A corrupt body is 400, which the app
      // does not resend.
      const body = await request.text();
      let requests;
      try { requests = JSON.parse(body).requests; } catch { return new Response("json", { status: 400 }); }
      if (!Array.isArray(requests)) return new Response("requests", { status: 400 });
      if (requests.find((r) => !allowed(r?.params))) return new Response("model or max_tokens", { status: 403 });
      if (await overCap(env, who)) return new Response("daily limit", { status: 429 });

      const key = JOB + job;
      let held = await settled(env, key);
      if (held === undefined) return new Response("in progress", { status: 409 });
      if (held) return resent(env, held, token);

      const claim = crypto.randomUUID();
      await env.STATE.put(key, JSON.stringify({ claim, at: Date.now() }), { expirationTtl: 3 * 24 * 3600 });
      await sleep(1000);
      if (!(await env.STATE.get(key))?.includes(claim)) {
        held = await settled(env, key);
        if (held) return resent(env, held, token);
        return new Response("in progress", { status: 409 });
      }
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
      if (!created.ok) {
        if ((await env.STATE.get(key))?.includes(claim)) await env.STATE.delete(key);
        return new Response(text, { status: created.status });
      }
      const batch = JSON.parse(text).id;
      const sent = Date.now();

      await env.STATE.put(REQ + batch, body, { expirationTtl: 2 * 24 * 3600 });
      await env.STATE.put(WATCH + batch,
        JSON.stringify({ batch, token, label, sandbox, job, sent, code: who.code, name: who.name }), keep(sent));
      // Last, so a request waiting on the claim finds the watch in place.
      await env.STATE.put(key, batch, { expirationTtl: 3 * 24 * 3600 });
      return Response.json({ batch, watched: !!token });
    }
    if (request.method === "POST" && url.pathname === "/watch") {
      // `label` names the session in the push — "Mandarin produce" — since two
      // languages can be out at once and "1 graded" alone says neither.
      // `job` is optional: the app's late /watch doesn't send it, and the push
      // falls back to the batch id.
      // The batch is usually tracked already, from /submit: keep its sent
      // time and any direct-grading claim, add the token.
      let given;
      try { given = await request.json(); } catch { return new Response("json", { status: 400 }); }
      const { batch, token, label, sandbox, job } = given;
      if (!batch || !token) return new Response("batch and token", { status: 400 });
      const prior = await env.STATE.get(WATCH + batch, "json");
      if (!prior && final(await env.STATE.get(RES + batch))) {
        return Response.json({ watching: batch }); // already graded directly; nothing to wait for
      }
      const sent = prior?.sent ?? prior?.since ?? Date.now();
      await env.STATE.put(WATCH + batch,
                          JSON.stringify({ ...prior, batch, token, label: label ?? prior?.label ?? null,
                                           sandbox: sandbox !== false, job: job || prior?.job || null, sent }),
                          keep(sent));
      return Response.json({ watching: batch });
    }
    // What the worker graded directly for a batch: 404 if it didn't step in,
    // 202 while it is grading, else the results file.
    if (request.method === "GET" && url.pathname === "/results") {
      const batch = url.searchParams.get("batch");
      if (!batch) return new Response("batch", { status: 400 });
      const stored = await env.STATE.get(RES + batch);
      if (!stored) return new Response("none", { status: 404 });
      if (!final(stored)) {
        // A claim nobody has renewed past its lease is abandoned: say so, and
        // the app reads the cancelled batch as it stands.
        const { at } = JSON.parse(stored);
        if (!at || Date.now() - at > LEASE_MS + 5 * 60 * 1000) return new Response("none", { status: 404 });
        return new Response("grading", { status: 202 });
      }
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
  const cap = params && MODELS[params.model];
  return !!cap && Number.isInteger(params.max_tokens) && params.max_tokens <= cap;
}

// /anthropic/v1/<path>: one message, or reading a batch the app was handed.
// A message is refused past the code's daily cap and charged to it after.
async function anthropic(request, env, url, who) {
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
    if (await overCap(env, who)) return new Response("daily limit", { status: 429 });
    headers["content-type"] = "application/json";
    headers["anthropic-beta"] = BETA;
  }
  const r = await fetch(`https://api.anthropic.com${path}`, { method: request.method, headers, body });
  if (message && r.ok) {
    const text = await r.text();
    let reply;
    try { reply = JSON.parse(text); } catch { reply = null; }
    await charge(env, who, [reply], false);
    return new Response(text, { status: r.status, headers: { "content-type": "application/json" } });
  }
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
    // One bad batch must not stop the rest; it is tried again next run.
    try { await check(env, name); } catch (e) { console.log(`${name}: ${e?.stack || e}`); }
  }
}

async function check(env, name) {
  // Listing can lag a delete; a key already gone was already pushed.
  const w = await env.STATE.get(name, "json");
  if (!w) return;
  if (w.direct) {
    // `true` is a claim from before leases: one that never finished.
    if (typeof w.direct === "number" && Date.now() - w.direct < LEASE_MS) return;
    // The run that claimed it died. If it stored its results, only the push is left.
    const stored = await env.STATE.get(RES + w.batch);
    if (final(stored)) return finish(env, name, w, countsOfLines(stored), w.batch);
  }
  const batch = await retrieve(env, w.batch);
  if (!batch) return;
  if (w.direct) {
    const body = await env.STATE.get(REQ + w.batch);
    if ((w.tries || 1) < TRIES && body) return gradeDirectly(env, name, w, JSON.parse(body).requests);
    // Give up: no direct results, so the app reads the cancelled batch.
    await env.STATE.delete(RES + w.batch);
    return finish(env, name, w, countsOf(batch), batch.id);
  }
  if (batch.processing_status === "ended") {
    await chargeBatch(env, w, batch);
    return finish(env, name, w, countsOf(batch), batch.id);
  }
  // The clock runs from when the batch was made, whatever /watch said.
  const sent = Math.min(w.sent ?? w.since ?? Infinity, Date.parse(batch.created_at) || Infinity);
  if (Date.now() - sent < DIRECT_AFTER_MS) return;
  const body = await env.STATE.get(REQ + w.batch);
  if (!body) return; // sent before requests were kept: wait it out
  await gradeDirectly(env, name, w, JSON.parse(body).requests);
}

// Pushes if the app gave a token, re-read in case /watch added it mid-run,
// then forgets the batch. A push that throws leaves the key for next run.
async function finish(env, name, w, counts, batchID) {
  const now = (await env.STATE.get(name, "json")) || w;
  if (now.token) await push(env, now, counts, batchID);
  await env.STATE.delete(name);
}

// Claims the watch for LEASE_MS, cancels the batch, grades every request with
// an ordinary call, stores the results and pushes. A failed call is stored as
// an error, which the app retries once on its own, as it does for a batch.
async function gradeDirectly(env, name, w, requests) {
  const at = Date.now();
  const sent = w.sent ?? w.since ?? at;
  await env.STATE.put(name, JSON.stringify({ ...w, sent, direct: at, tries: (w.tries || 0) + 1 }), keep(sent));
  await env.STATE.put(RES + w.batch, JSON.stringify({ pending: true, at }), { expirationTtl: 3 * 24 * 3600 });
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

  const stored = lines.map((l) => JSON.stringify(l)).join("\n");
  await env.STATE.put(RES + w.batch, stored, { expirationTtl: 3 * 24 * 3600 });
  if (w.code) await charge(env, w, lines.map((l) => l.result?.message), false);
  await finish(env, name, w, countsOfLines(stored), w.batch);
}

// Direct results stored, not a pending claim.
function final(stored) {
  return !!stored && !stored.startsWith('{"pending"');
}

function countsOfLines(stored) {
  const lines = stored.split("\n").filter(Boolean).map((l) => JSON.parse(l));
  const succeeded = lines.filter((l) => l.result?.type === "succeeded").length;
  return { succeeded, failed: lines.length - succeeded };
}

// A watch lives until its batch has expired on Anthropic's side, counted from
// when it was sent, not from the last write.
function keep(sent) {
  const now = Math.floor(Date.now() / 1000);
  return { expiration: Math.max(Math.floor((sent + GIVE_UP_MS) / 1000), now + 60) };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The batch a job already became, waiting out a claim another request holds.
// Null when nothing holds the job (or its claim is stale), undefined when the
// claim is still live after the wait.
async function settled(env, key) {
  for (let i = 0; ; i++) {
    const v = await env.STATE.get(key);
    if (!v) return null;
    if (!v.startsWith("{")) return v;
    if (Date.now() - (JSON.parse(v).at || 0) > CLAIM_MS) return null;
    if (i === 20) return undefined;
    await sleep(1000);
  }
}

// A resent job's batch. A token the first upload lacked is added here, and
// `watched` says whether a push is coming, so the app skips /watch.
async function resent(env, batch, token) {
  const w = await env.STATE.get(WATCH + batch, "json");
  if (w && token && !w.token) {
    await env.STATE.put(WATCH + batch, JSON.stringify({ ...w, token }), keep(w.sent ?? w.since ?? Date.now()));
  }
  return Response.json({ batch, resent: true, watched: !!(w && (w.token || token)) });
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

// MARK: Spend and disputes

function today() {
  return new Date(Date.now()).toISOString().slice(0, 10);
}

// What one reply cost, in dollars.
function cost(reply, batched) {
  const price = PRICES[reply?.model?.replace(/-\d{8}$/, "")] || PRICES["claude-opus-5"];
  const u = reply?.usage || {};
  const dollars = ((u.input_tokens || 0) * price[0] + (u.output_tokens || 0) * price[1]
    + (u.cache_read_input_tokens || 0) * price[2] + (u.cache_creation_input_tokens || 0) * price[3]) / 1e6;
  return batched ? dollars / 2 : dollars;
}

function ledger(env, path, body) {
  const stub = env.LEDGER.get(env.LEDGER.idFromName("ledger"));
  return stub.fetch(new Request(`https://ledger${path}`, {
    method: body ? "POST" : "GET", body: body ? JSON.stringify(body) : undefined,
  }));
}

async function charge(env, who, replies, batched) {
  const got = replies.filter((r) => r && r.usage);
  if (!got.length || !who?.code) return;
  const sum = (f) => got.reduce((n, r) => n + (r.usage[f] || 0), 0);
  await ledger(env, "/charge", {
    day: today(), code: who.code, name: who.name, calls: got.length,
    dollars: got.reduce((n, r) => n + cost(r, batched), 0),
    input: sum("input_tokens"), output: sum("output_tokens"),
  });
}

// An ended batch's results, read once, charged at batch price.
async function chargeBatch(env, w, batch) {
  if (!w.code || !batch.results_url) return;
  const r = await fetch(batch.results_url, {
    headers: { "x-api-key": env.ANTHROPIC_KEY.trim(), "anthropic-version": "2023-06-01" },
  });
  if (!r.ok) return;
  const replies = (await r.text()).split("\n").filter(Boolean).map((l) => {
    try { return JSON.parse(l).result?.message; } catch { return null; }
  });
  await charge(env, w, replies, true);
}

async function overCap(env, who) {
  const cap = Number(env.DAILY_CAP_USD || 2);
  const r = await ledger(env, `/spent?day=${today()}&code=${encodeURIComponent(who.code)}`);
  const { dollars } = await r.json();
  return dollars >= cap;
}

// Owner only: ?key=ADMIN_KEY. Spend per code per day for the last two weeks,
// and the latest disputes. ?format=json for the raw rows.
async function stats(env, url) {
  if (!env.ADMIN_KEY || url.searchParams.get("key") !== env.ADMIN_KEY.trim()) {
    return new Response("not found", { status: 404 });
  }
  const data = await (await ledger(env, "/stats")).json();
  if (url.searchParams.get("format") === "json") return Response.json(data);
  const esc = (v) => String(v ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  const rows = data.usage.map((u) => `<tr><td>${esc(u.day)}</td><td>${esc(u.name)}</td><td>${u.calls}</td>`
    + `<td>${(u.input / 1000).toFixed(0)}k</td><td>${(u.output / 1000).toFixed(0)}k</td><td>$${u.dollars.toFixed(2)}</td></tr>`).join("");
  const disputes = data.disputes.map((d) => `<tr><td>${esc(d.at?.slice(0, 16))}</td><td>${esc(d.name)}</td>`
    + `<td>${esc(d.language)} ${esc(d.mode)}</td><td>${esc(d.attempt)}</td><td>${esc(d.finding?.kind)}: ${esc(d.finding?.text)}</td>`
    + `<td>${esc(d.note)}</td></tr>`).join("");
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>gentence stats</title><style>body{font:13px ui-monospace,monospace;margin:16px}table{border-collapse:collapse;margin-bottom:24px}
td,th{border:1px solid #999;padding:3px 6px;text-align:left;vertical-align:top}</style>
<h3>Spend (UTC days, last 14)</h3><table><tr><th>day</th><th>who</th><th>calls</th><th>in</th><th>out</th><th>$</th></tr>${rows}</table>
<h3>Disputed findings (latest 100)</h3><table><tr><th>when</th><th>who</th><th>what</th><th>attempt</th><th>finding</th><th>note</th></tr>${disputes}</table>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
}

// One instance for the whole worker. A Durable Object runs one request at a
// time, so read-add-write here never loses a charge.
export class Ledger {
  constructor(state) { this.storage = state.storage; }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/charge") {
      const c = await request.json();
      const key = `use|${c.day}|${c.code}`;
      const row = (await this.storage.get(key)) || { day: c.day, name: c.name, calls: 0, input: 0, output: 0, dollars: 0 };
      row.name = c.name; row.calls += c.calls; row.input += c.input; row.output += c.output; row.dollars += c.dollars;
      await this.storage.put(key, row);
      return Response.json(row);
    }
    if (url.pathname === "/spent") {
      const row = await this.storage.get(`use|${url.searchParams.get("day")}|${url.searchParams.get("code")}`);
      return Response.json({ dollars: row?.dollars || 0 });
    }
    if (url.pathname === "/dispute") {
      const d = await request.json();
      await this.storage.put(`dispute|${d.at}|${crypto.randomUUID()}`, d);
      return Response.json({ ok: true });
    }
    if (url.pathname === "/stats") {
      const since = new Date(Date.now() - 14 * 86400 * 1000).toISOString().slice(0, 10);
      const usage = [...(await this.storage.list({ prefix: "use|" })).values()]
        .filter((u) => u.day >= since).sort((a, b) => (b.day + a.name).localeCompare(a.day + b.name));
      const disputes = [...(await this.storage.list({ prefix: "dispute|", reverse: true, limit: 100 })).values()];
      return Response.json({ usage, disputes });
    }
    return new Response("not found", { status: 404 });
  }
}
