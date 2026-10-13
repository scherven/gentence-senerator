// Runs the worker against a fake KV and a mocked fetch: `node worker/test/harness.mjs`.
// Time is faked (Date.now offset, timers 100x faster), so leases and the
// 20-minute switch can be crossed without waiting.
import assert from "node:assert/strict";

let offset = 0;
const realNow = Date.now.bind(Date);
Date.now = () => realNow() + offset;
const advance = (ms) => { offset += ms; };
const realTimeout = globalThis.setTimeout;
globalThis.setTimeout = (fn, ms, ...a) => realTimeout(fn, Math.ceil((ms || 0) / 100), ...a);
const tick = (ms = 5) => new Promise((r) => realTimeout(r, ms));

class KV {
  constructor() { this.m = new Map(); this.lists = 0; }
  async get(k, t) {
    await tick(1);
    const e = this.m.get(k);
    if (!e || (e.exp && e.exp * 1000 < Date.now())) return null;
    return (t === "json" || t?.type === "json") ? JSON.parse(e.v) : e.v;
  }
  async put(k, v, o = {}) {
    await tick(1);
    const exp = o.expiration ?? (o.expirationTtl ? Math.floor(Date.now() / 1000) + o.expirationTtl : null);
    this.m.set(k, { v, exp });
  }
  async delete(k) { await tick(1); this.m.delete(k); }
  async list({ prefix }) {
    this.lists++;
    return { keys: [...this.m.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })) };
  }
  json(k) { const e = this.m.get(k); return e && JSON.parse(e.v); }
  raw(k) { return this.m.get(k)?.v; }
}

// The fake Anthropic and APNs.
let api;
function reset() {
  api = { n: 0, batches: {}, created: 0, pushes: [], createFails: 0,
          messages: "ok", pushThrows: 0, retrieveThrows: new Set() };
}
globalThis.fetch = async (input, init = {}) => {
  const u = new URL(String(input));
  const method = init.method || "GET";
  await tick(3);
  if (u.host.includes("push.apple.com")) {
    if (api.pushThrows > 0) { api.pushThrows--; throw new Error("network"); }
    api.pushes.push(JSON.parse(init.body));
    return new Response("", { status: 200 });
  }
  let m;
  if (method === "POST" && u.pathname === "/v1/messages/batches") {
    api.created++;
    if (api.createFails > 0) { api.createFails--; return new Response("overloaded", { status: 529 }); }
    const id = `msgbatch_${++api.n}`;
    api.batches[id] = { id, processing_status: "in_progress", created_at: new Date(Date.now()).toISOString(),
                        request_counts: { succeeded: 0, errored: 0, expired: 0, canceled: 0 } };
    await tick(20);
    return Response.json(api.batches[id]);
  }
  if ((m = u.pathname.match(/^\/v1\/messages\/batches\/(\w+)\/cancel$/))) {
    const b = api.batches[m[1]];
    b.processing_status = "ended"; b.request_counts.canceled = 2;
    return Response.json(b);
  }
  if ((m = u.pathname.match(/^\/v1\/messages\/batches\/(\w+)$/))) {
    if (api.retrieveThrows.has(m[1])) throw new Error("boom");
    return Response.json(api.batches[m[1]]);
  }
  if (method === "POST" && u.pathname === "/v1/messages") {
    if (api.messages === "hang") return new Promise(() => {});
    return Response.json({ id: "msg", model: JSON.parse(init.body).model, content: [{ type: "text", text: "ok" }],
                           usage: { input_tokens: 100000, output_tokens: 10000 } });
  }
  throw new Error(`unmocked ${method} ${u}`);
};

const { default: worker, Ledger } = await import(new URL("../src/index.js", import.meta.url));

// A Durable Object's storage, enough for the Ledger.
function fakeLedger() {
  const m = new Map();
  const storage = {
    get: async (k) => structuredClone(m.get(k)),
    put: async (k, v) => { m.set(k, structuredClone(v)); },
    list: async ({ prefix, reverse, limit }) => {
      let keys = [...m.keys()].filter((k) => k.startsWith(prefix)).sort();
      if (reverse) keys.reverse();
      if (limit) keys = keys.slice(0, limit);
      return new Map(keys.map((k) => [k, structuredClone(m.get(k))]));
    },
  };
  const ledger = new Ledger({ storage });
  return { idFromName: () => "ledger", get: () => ({ fetch: (r) => ledger.fetch(r) }) };
}

async function makeEnv() {
  const STATE = new KV();
  await STATE.put("invite:ABCD-EFGH", JSON.stringify({ name: "test" }));
  const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]);
  const der = Buffer.from(await crypto.subtle.exportKey("pkcs8", kp.privateKey)).toString("base64");
  return {
    STATE, PER_INVITE: { limit: async () => ({ success: true }) }, LEDGER: fakeLedger(),
    DAILY_CAP_USD: "2", ADMIN_KEY: "secret",
    ANTHROPIC_KEY: "k", APNS_KEY: `-----BEGIN PRIVATE KEY-----\n${der}\n-----END PRIVATE KEY-----`,
    APNS_KEY_ID: "KID", APNS_TEAM_ID: "TEAM", APNS_TOPIC: "topic",
  };
}

const BODY = JSON.stringify({ requests: [
  { custom_id: "a", params: { model: "claude-opus-5", max_tokens: 1000, messages: [] } },
  { custom_id: "b", params: { model: "claude-opus-5", max_tokens: 1000, messages: [] } },
] });
const call = (env, path, { method = "GET", headers = {}, body } = {}) =>
  worker.fetch(new Request(`https://w.test${path}`, {
    method, body, headers: { "x-invite": "ABCD-EFGH", ...headers } }), env);
const submit = (env, job, { token, body = BODY } = {}) => call(env, "/submit", {
  method: "POST", body, headers: { "x-job-id": job, "x-label": "French produce", ...(token ? { "x-token": token } : {}) } });
const poll = (env) => worker.scheduled({}, env, { waitUntil: (p) => p }) ?? null;
async function runPoll(env) {
  let p; await worker.scheduled({}, env, { waitUntil: (x) => { p = x; } }); await p;
}

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test("6: corrupt /submit body is 400, not 500, and claims nothing", async () => {
  const env = await makeEnv();
  const r = await submit(env, "j1", { body: "{not json" });
  assert.equal(r.status, 400);
  assert.equal(env.STATE.raw("job:j1"), undefined);
  assert.equal((await submit(env, "j2", { body: '{"requests":3}' })).status, 400);
});

test("2: concurrent submits of one job make one batch, both get it", async () => {
  const env = await makeEnv();
  const [a, b] = await Promise.all([submit(env, "j", { token: "t" }), submit(env, "j", { token: "t" })]);
  assert.equal(a.status, 200); assert.equal(b.status, 200);
  const [ja, jb] = [await a.json(), await b.json()];
  assert.equal(api.created, 1);
  assert.equal(ja.batch, jb.batch);
  assert.ok(ja.watched && jb.watched);
  // A staggered resend is handed the same batch.
  const c = await (await submit(env, "j", { token: "t" })).json();
  assert.equal(c.batch, ja.batch); assert.equal(c.resent, true); assert.equal(api.created, 1);
});

test("2: second request arriving mid-creation waits and gets the winner's batch", async () => {
  const env = await makeEnv();
  const a = submit(env, "j", {});
  await tick(15); // a's claim is down, its batch not yet made
  const b = submit(env, "j", { token: "t" });
  const [ra, rb] = await Promise.all([a, b]);
  const [ja, jb] = [await ra.json(), await rb.json()];
  assert.equal(api.created, 1);
  assert.equal(ja.batch, jb.batch);
  // b carried a token a lacked: it is now on the watch.
  assert.equal(env.STATE.json(`watch:${ja.batch}`).token, "t");
  assert.equal(jb.watched, true);
});

test("2: failed create releases the claim; retry makes the batch", async () => {
  const env = await makeEnv();
  api.createFails = 1;
  assert.equal((await submit(env, "j")).status, 529);
  assert.equal(env.STATE.raw("job:j"), undefined);
  assert.equal((await submit(env, "j")).status, 200);
});

test("2: a live claim that never resolves gives 409; a stale one is retaken", async () => {
  const env = await makeEnv();
  await env.STATE.put("job:j", JSON.stringify({ claim: "x", at: Date.now() }));
  assert.equal((await submit(env, "j")).status, 409);
  advance(61 * 1000);
  const r = await submit(env, "j");
  assert.equal(r.status, 200);
  assert.equal(api.created, 1);
});

test("3: a batch sent without a token is still graded directly at 20 min, no push", async () => {
  const env = await makeEnv();
  const { batch, watched } = await (await submit(env, "j")).json();
  assert.equal(watched, false);
  assert.ok(env.STATE.json(`watch:${batch}`));
  advance(19 * 60 * 1000); await runPoll(env);
  assert.equal(env.STATE.raw(`res:${batch}`), undefined);
  advance(2 * 60 * 1000); await runPoll(env);
  assert.ok(env.STATE.raw(`res:${batch}`).includes('"succeeded"'));
  assert.equal(env.STATE.raw(`watch:${batch}`), undefined);
  assert.equal(api.pushes.length, 0);
  const res = await call(env, `/results?batch=${batch}`);
  assert.equal(res.status, 200);
});

test("3: a late /watch keeps the original sent time and adds the token", async () => {
  const env = await makeEnv();
  const { batch } = await (await submit(env, "j")).json();
  const sent = env.STATE.json(`watch:${batch}`).sent;
  advance(15 * 60 * 1000);
  const w = await call(env, "/watch", { method: "POST", body: JSON.stringify({ batch, token: "t", label: "L" }) });
  assert.equal(w.status, 200);
  assert.equal(env.STATE.json(`watch:${batch}`).sent, sent);
  advance(6 * 60 * 1000); await runPoll(env); // 21 min after the send, 6 after the watch
  assert.equal(api.pushes.length, 1);
  assert.equal(api.pushes[0].batch, batch);
});

test("3: a batch that ends normally pushes only if it has a token", async () => {
  const env = await makeEnv();
  const a = (await (await submit(env, "a")).json()).batch;
  const b = (await (await submit(env, "b", { token: "t" })).json()).batch;
  for (const id of [a, b]) { api.batches[id].processing_status = "ended"; api.batches[id].request_counts.succeeded = 2; }
  await runPoll(env);
  assert.equal(api.pushes.length, 1); assert.equal(api.pushes[0].batch, b);
  assert.equal(env.STATE.raw(`watch:${a}`), undefined);
});

test("1: a direct grading that dies is retaken after the lease and pushes", async () => {
  const env = await makeEnv();
  const { batch } = await (await submit(env, "j", { token: "t" })).json();
  advance(21 * 60 * 1000);
  api.messages = "hang";
  const p = { done: false };
  worker.scheduled({}, env, { waitUntil: (x) => { x.then(() => { p.done = true; }); } });
  await tick(100); // the run has claimed and is stuck on the calls; treat it as dead
  assert.equal(p.done, false);
  assert.equal(typeof env.STATE.json(`watch:${batch}`).direct, "number");
  assert.equal((await call(env, `/results?batch=${batch}`)).status, 202);
  api.messages = "ok";
  advance(10 * 60 * 1000); await runPoll(env); // inside the lease: left alone
  assert.equal(api.pushes.length, 0);
  advance(7 * 60 * 1000); await runPoll(env);   // past it: retaken
  assert.equal(api.pushes.length, 1);
  assert.equal((await call(env, `/results?batch=${batch}`)).status, 200);
  assert.equal(env.STATE.raw(`watch:${batch}`), undefined);
});

test("1: results stored but push lost: retake only pushes, no regrading", async () => {
  const env = await makeEnv();
  const { batch } = await (await submit(env, "j", { token: "t" })).json();
  advance(21 * 60 * 1000);
  api.pushThrows = 1;
  await runPoll(env); // grades, stores, push throws
  assert.ok(env.STATE.raw(`res:${batch}`).includes("succeeded"));
  assert.ok(env.STATE.json(`watch:${batch}`).direct);
  advance(17 * 60 * 1000);
  const before = env.STATE.raw(`res:${batch}`);
  await runPoll(env);
  assert.equal(api.pushes.length, 1);
  assert.equal(api.pushes[0].aps.alert.body, "French produce: 2 graded.");
  assert.equal(env.STATE.raw(`res:${batch}`), before);
});

test("1: legacy direct:true is retaken; after TRIES the app is told to read the batch", async () => {
  const env = await makeEnv();
  const { batch } = await (await submit(env, "j", { token: "t" })).json();
  const w = env.STATE.json(`watch:${batch}`);
  await env.STATE.put(`watch:${batch}`, JSON.stringify({ ...w, direct: true }));
  await env.STATE.put(`res:${batch}`, '{"pending":true}');
  assert.equal((await call(env, `/results?batch=${batch}`)).status, 404); // stale legacy pending
  api.messages = "hang";
  worker.scheduled({}, env, { waitUntil: () => {} }); await tick(100); // try 1 (retake)
  advance(17 * 60 * 1000);
  worker.scheduled({}, env, { waitUntil: () => {} }); await tick(100); // try 2
  assert.equal(env.STATE.json(`watch:${batch}`).tries, 2);
  advance(17 * 60 * 1000);
  worker.scheduled({}, env, { waitUntil: () => {} }); await tick(100); // try 3
  assert.equal(env.STATE.json(`watch:${batch}`).tries, 3);
  advance(17 * 60 * 1000);
  await runPoll(env); // gives up
  assert.equal(env.STATE.raw(`watch:${batch}`), undefined);
  assert.equal(env.STATE.raw(`res:${batch}`), undefined);
  assert.equal((await call(env, `/results?batch=${batch}`)).status, 404);
  assert.equal(api.pushes.length, 1);
  assert.equal(api.pushes[0].aps.alert.body, "French produce: 0 graded, 2 failed.");
});

test("5: one watch throwing does not stop the others; a thrown push is retried", async () => {
  const env = await makeEnv();
  const a = (await (await submit(env, "a", { token: "t" })).json()).batch;
  const b = (await (await submit(env, "b", { token: "t" })).json()).batch;
  api.retrieveThrows.add(a);
  api.batches[b].processing_status = "ended";
  api.pushThrows = 1;
  await runPoll(env);
  assert.equal(api.pushes.length, 0);
  assert.ok(env.STATE.raw(`watch:${b}`)); // kept: the push never went
  await runPoll(env);
  assert.equal(api.pushes.length, 1); assert.equal(api.pushes[0].batch, b);
  assert.equal(env.STATE.raw(`watch:${b}`), undefined);
  assert.ok(env.STATE.raw(`watch:${a}`));
});

test("4: /health does no KV list", async () => {
  const env = await makeEnv();
  const r = await worker.fetch(new Request("https://w.test/health"), env);
  assert.equal(r.status, 200);
  assert.equal(env.STATE.lists, 0);
});

test("7: a message is charged to its code at its model's price", async () => {
  const env = await makeEnv();
  const r = await call(env, "/anthropic/v1/messages", { method: "POST",
    body: JSON.stringify({ model: "claude-sonnet-5-5", max_tokens: 1000, messages: [] }) });
  assert.equal(r.status, 200);
  assert.equal((await r.json()).content[0].text, "ok");
  const s = await (await worker.fetch(new Request("https://w.test/stats?key=secret&format=json"), env)).json();
  assert.equal(s.usage.length, 1);
  assert.equal(s.usage[0].name, "test");
  assert.equal(s.usage[0].calls, 1);
  // 100k in at $2/M + 10k out at $10/M
  assert.ok(Math.abs(s.usage[0].dollars - 0.3) < 1e-9);
});

test("7: past the daily cap, messages and submits are refused", async () => {
  const env = await makeEnv();
  env.DAILY_CAP_USD = "1";
  const send = () => call(env, "/anthropic/v1/messages", { method: "POST",
    body: JSON.stringify({ model: "claude-opus-5", max_tokens: 1000, messages: [] }) });
  assert.equal((await send()).status, 200); // $0.75
  assert.equal((await send()).status, 200); // $1.50: the check is before, so one overshoots
  const r = await send();
  assert.equal(r.status, 429);
  assert.equal(await r.text(), "daily limit");
  assert.equal((await submit(env, "j9")).status, 429);
});

test("7: a dispute is kept with who sent it; /stats is closed without the key", async () => {
  const env = await makeEnv();
  const r = await call(env, "/dispute", { method: "POST",
    body: JSON.stringify({ language: "german", mode: "produce", attempt: "Ich habe gegangen",
                           finding: { kind: "auxiliary", text: "habe → bin" }, note: "fine?" }) });
  assert.equal(r.status, 200);
  assert.equal((await worker.fetch(new Request("https://w.test/stats"), env)).status, 404);
  assert.equal((await worker.fetch(new Request("https://w.test/stats?key=nope"), env)).status, 404);
  const s = await (await worker.fetch(new Request("https://w.test/stats?key=secret&format=json"), env)).json();
  assert.equal(s.disputes.length, 1);
  assert.equal(s.disputes[0].name, "test");
  assert.equal(s.disputes[0].note, "fine?");
  const html = await (await worker.fetch(new Request("https://w.test/stats?key=secret"), env)).text();
  assert.ok(html.includes("habe → bin"));
});

test("7: direct grading charges the batch's code", async () => {
  const env = await makeEnv();
  const { batch } = await (await submit(env, "j1")).json();
  advance(21 * 60 * 1000);
  await runPoll(env);
  const s = await (await worker.fetch(new Request("https://w.test/stats?key=secret&format=json"), env)).json();
  assert.equal(s.usage[0]?.calls, 2, `charged for ${batch}`);
});

let failed = 0;
for (const [name, fn] of tests) {
  reset(); offset = 0;
  try { await fn(); console.log(`ok   ${name}`); }
  catch (e) { failed++; console.log(`FAIL ${name}\n${e.stack}`); }
}
console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
