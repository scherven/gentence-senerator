// Watches the app's grading batches and pushes when one ends.
//
// The phone creates the batch itself and registers it here with its device
// token. Nothing else is stored: the results stay with Anthropic until the
// app downloads them.
//
// One KV key per watched batch, `watch:<id>`. A single shared list was
// read-modify-written by both /watch and the cron, so a batch registered
// while another was being cleared could be dropped and never notify — with
// two languages out at once that is exactly the case that happens.
// The cron runs every two minutes because listing keys is capped at 1,000 a
// day on the free tier.

const WATCH = "watch:";
// The batch a job became, so a resent job returns it instead of paying twice.
const JOB = "job:";
const APNS_JWT = "apns-jwt";
// A batch that has not ended in this long has expired on Anthropic's side
// (24h) and will never end here either.
const GIVE_UP_MS = 26 * 3600 * 1000;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // The app's background upload lands here: create the batch and watch it
    // in one step, so a batch can never exist without being watched. The
    // phone's upload can be retried by iOS at any point, so the job id makes
    // it idempotent.
    if (request.method === "POST" && url.pathname === "/submit") {
      if (request.headers.get("x-watch-secret") !== env.WATCH_SECRET) {
        return new Response("no", { status: 401 });
      }
      const job = request.headers.get("x-job-id");
      if (!job) return new Response("x-job-id", { status: 400 });
      const token = request.headers.get("x-token") || null;
      const label = request.headers.get("x-label") || null;
      const sandbox = request.headers.get("x-sandbox") !== "0";

      const existing = await env.STATE.get(JOB + job);
      if (existing) return Response.json({ batch: existing, resent: true });

      const created = await fetch("https://api.anthropic.com/v1/messages/batches", {
        method: "POST",
        headers: {
          "x-api-key": env.ANTHROPIC_KEY.trim(),
          "anthropic-version": "2023-06-01",
          "content-type": "application/json",
        },
        body: request.body,
      });
      const text = await created.text();
      if (!created.ok) return new Response(text, { status: created.status });
      const batch = JSON.parse(text).id;

      await env.STATE.put(JOB + job, batch, { expirationTtl: 3 * 24 * 3600 });
      if (token) {
        await env.STATE.put(WATCH + batch,
          JSON.stringify({ batch, token, label, sandbox, job, since: Date.now() }),
          { expirationTtl: GIVE_UP_MS / 1000 });
      }
      return Response.json({ batch, watched: !!token });
    }
    if (request.method === "POST" && url.pathname === "/watch") {
      if (request.headers.get("x-watch-secret") !== env.WATCH_SECRET) {
        return new Response("no", { status: 401 });
      }
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
    if (url.pathname === "/health") {
      const { keys } = await env.STATE.list({ prefix: WATCH });
      return Response.json({ watching: keys.length });
    }
    return new Response("not found", { status: 404 });
  },

  async scheduled(_event, env, ctx) {
    ctx.waitUntil(poll(env));
  },
};

async function poll(env) {
  const { keys } = await env.STATE.list({ prefix: WATCH });
  for (const { name } of keys) {
    // Listing can lag a delete; a key already gone was already pushed.
    const w = await env.STATE.get(name, "json");
    if (!w) continue;
    const batch = await retrieve(env, w.batch);
    if (batch?.processing_status !== "ended") continue;
    await env.STATE.delete(name);
    await push(env, w, batch);
  }
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

async function push(env, w, batch) {
  const { token, label } = w;
  const c = batch.request_counts;
  const graded = c.succeeded;
  const failed = c.errored + c.expired + c.canceled;
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
      aps: { alert: { title: "Feedback's in", body }, sound: "default" },
      // What a tap opens. Watches stored before job ids were kept have only
      // the batch, which the app matches too.
      batch: batch.id,
      ...(w.job ? { job: w.job } : {}),
    }),
  });
  // A bad token is logged and dropped; retrying would only fail again.
  if (!response.ok) console.log(`push ${batch.id}: ${response.status} ${await response.text()}`);
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
