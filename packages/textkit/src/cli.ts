#!/usr/bin/env node
/**
 * textkit CLI - TextKit from the terminal.
 *
 * Agents reach for a shell before an SDK, so every command works
 * non-interactively, reads TEXTKIT_API_KEY, and has a --json mode that prints
 * raw API objects with no decoration.
 *
 *   npx jointextkit login                 approve in the browser; a test key lands in ~/.textkit.json
 *   npx jointextkit login --key ssms_sk_...   store a key you already have (or pipe it on stdin)
 *   npx jointextkit listen --forward-to http://localhost:3000/webhooks
 *   npx jointextkit trigger message.received
 *   npx jointextkit send --to +1... "body"            (--from is optional)
 *   npx jointextkit verify +14155550132
 *   npx jointextkit verify +14155550132 482193
 *   npx jointextkit numbers search 415 | buy +1... | release +1... | list
 *   npx jointextkit lookup +14155550132
 *   npx jointextkit messages [--limit 10]
 *   npx jointextkit events [--limit 10]
 */

import { spawn } from 'child_process';
import { randomBytes } from 'crypto';
import { readFileSync, writeFileSync } from 'fs';
import { homedir, hostname } from 'os';
import { join } from 'path';
import { TextKit, TextKitError, VERSION, defaultBaseUrl, signedWebhookRequest, type SmsEvent } from './index';

const CONFIG_PATH = join(homedir(), '.textkit.json');
// Where `simplesms login` and `deliveredsms login` stored the key before each
// rename, newest first. Read as a fallback so nobody has to log in again; never written.
const LEGACY_CONFIG_PATHS = [join(homedir(), '.simplesms.json'), join(homedir(), '.deliveredsms.json')];

const HELP = `textkit: SMS, verification, and phone numbers from the terminal

Usage
  textkit login                          approve in your browser; stores a new TEST key
  textkit login --key <key>              store a key you already have (or pipe it on stdin)
  textkit listen [--forward-to <url>]    stream your events; with a URL, replay each one to
                                           your local server, signed like a real webhook
  textkit trigger <event>                fire a sandbox event: message.sent, message.delivered,
                                           message.failed, message.received
  textkit send --to <num> <body...>      --from <num> is optional when the account has one
                                           number for the key's mode
  textkit verify <phone|email>           send a one-time code (an email address emails it)
  textkit verify <phone|email> <code>    check the code
  textkit numbers list
  textkit numbers search <area-code>
  textkit numbers buy <phone>
  textkit numbers release <phone>
  textkit lookup <phone>
  textkit messages [--limit <n>]
  textkit events [--limit <n>]

Flags
  --json              raw API output (for scripts and agents); one JSON object per line for listen
  --key <key>         API key for this invocation only (with login: the key to store)
  --forward-to <url>  listen: POST each event here, e.g. http://localhost:3000/webhooks
  --events <a,b>      listen: only these event types
  --secret <whsec>    listen: sign with this secret instead of a new one per session
  --no-browser        login: print the URL, do not open it

Keys: \`textkit login\`, or set TEXTKIT_API_KEY (free sandbox key at https://jointextkit.com/console)
Docs: https://jointextkit.com/docs/cli  (llms.txt available)`;

interface Flags {
  json: boolean;
  key?: string;
  from?: string;
  to?: string;
  spam: boolean;
  limit?: number;
  forwardTo?: string;
  events?: string[];
  secret?: string;
  noBrowser: boolean;
  rest: string[];
}

function parseArgs(argv: string[]): Flags {
  const flags: Flags = { json: false, spam: false, noBrowser: false, rest: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') flags.json = true;
    else if (a === '--spam') flags.spam = true;
    else if (a === '--key') flags.key = argv[++i];
    else if (a === '--from') flags.from = argv[++i];
    else if (a === '--to') flags.to = argv[++i];
    else if (a === '--limit') flags.limit = Number(argv[++i]);
    else if (a === '--forward-to' || a === '-f') flags.forwardTo = argv[++i];
    else if (a === '--events') flags.events = (argv[++i] || '').split(',').map((e) => e.trim()).filter(Boolean);
    else if (a === '--secret') flags.secret = argv[++i];
    else if (a === '--no-browser') flags.noBrowser = true;
    else flags.rest.push(a);
  }
  return flags;
}

function loadStoredKey(): string | undefined {
  for (const path of [CONFIG_PATH, ...LEGACY_CONFIG_PATHS]) {
    try {
      const cfg = JSON.parse(readFileSync(path, 'utf8'));
      if (typeof cfg.apiKey === 'string') return cfg.apiKey;
    } catch {
      // Missing or unreadable: try the next one.
    }
  }
  return undefined;
}

function out(flags: Flags, data: unknown, human: () => void): void {
  if (flags.json) console.log(JSON.stringify(data, null, 2));
  else human();
}

function fail(message: string): never {
  console.error(`error: ${message}`);
  process.exit(1);
}

const KEY_SHAPE = /^(tk|ssms|dsms|resms)_sk_(test|live)_[A-Za-z0-9]{20,}$/;
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
/** `ssms_sk_test_AbCd...`: enough to recognise a key in the console list, never the key. */
const keyLabel = (key: string) => `${key.slice(0, key.search(/_(test|live)_/) + 10)}...`;

function saveKey(key: string): void {
  // The file format is one field, unchanged since the first release.
  writeFileSync(CONFIG_PATH, `${JSON.stringify({ apiKey: key }, null, 2)}\n`, { mode: 0o600 });
}

/**
 * A key piped on stdin (`echo $KEY | textkit login`). Returns '' when stdin
 * is a terminal, is closed, or stays silent: agents and CI often hand a
 * process an open pipe nobody writes to, and waiting on it would hang the
 * browser login forever.
 */
function readPipedKey(waitMs = 400): Promise<string> {
  if (process.stdin.isTTY) return Promise.resolve('');
  return new Promise((resolve) => {
    let buf = '';
    let settled = false;
    const done = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      process.stdin.removeAllListeners('data');
      process.stdin.removeAllListeners('end');
      process.stdin.removeAllListeners('error');
      process.stdin.pause();
      // Without this an idle pipe keeps the process alive after the login finishes.
      (process.stdin as unknown as { unref?: () => void }).unref?.();
      resolve(buf.trim().split(/\s+/)[0] || '');
    };
    const timer = setTimeout(done, waitMs);
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk: string) => {
      buf += chunk;
      if (buf.includes('\n')) done();
    });
    process.stdin.on('end', done);
    process.stdin.on('error', done);
  });
}

/** Best effort: a login must work on a machine with no browser to open. */
function openBrowser(url: string): boolean {
  if (!/^https?:\/\//.test(url)) return false;
  const env = process.env;
  if (env.TEXTKIT_NO_BROWSER || env.CI) return false;
  if (process.platform === 'linux' && !env.DISPLAY && !env.WAYLAND_DISPLAY) return false;
  const [cmd, args]: [string, string[]] =
    process.platform === 'darwin'
      ? ['open', [url]]
      : process.platform === 'win32'
        ? ['cmd', ['/c', 'start', '""', url.replace(/&/g, '^&')]]
        : ['xdg-open', [url]];
  try {
    const child = spawn(cmd, args, { stdio: 'ignore', detached: true });
    child.on('error', () => {});
    child.unref();
    return true;
  } catch {
    return false;
  }
}

interface LoginStart {
  device_code: string;
  user_code: string;
  verification_url: string;
  verification_url_complete: string;
  expires_in: number;
  interval: number;
}

interface LoginPoll {
  status: 'pending' | 'approved' | 'denied' | 'expired';
  api_key?: string;
  key_id?: string;
  account?: { id: string; name: string | null };
  sandbox_number?: string | null;
}

type LoginError = { error?: { code?: string; message?: string } };

/** The two login calls carry no API key: they are how a terminal gets one. */
async function loginRequest<T>(path: string, body: unknown): Promise<{ status: number; json: Partial<T> & LoginError }> {
  const res = await fetch(`${defaultBaseUrl()}/v1${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'User-Agent': `jointextkit-cli/${VERSION}` },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  let json: Partial<T> & LoginError = {};
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = {};
  }
  return { status: res.status, json };
}

/** Store a key the developer already has, and show its sandbox number. */
async function loginWithKey(key: string, flags: Flags): Promise<void> {
  if (!KEY_SHAPE.test(key)) fail('that does not look like a TextKit key (ssms_sk_test_... or ssms_sk_live_...)');
  saveKey(key);
  const test = /_sk_test_/.test(key);
  let sandbox: string | null = null;
  if (test) {
    try {
      sandbox = (await new TextKit(key).numbers.list()).data.find((n) => n.mode === 'test')?.phone_number ?? null;
    } catch {
      // The key is stored either way; an unreachable API must not fail a login.
    }
  }
  out(flags, { status: 'stored', config_path: CONFIG_PATH, mode: test ? 'test' : 'live', sandbox_number: sandbox }, () => {
    console.log(`Saved to ${CONFIG_PATH} (${test ? 'sandbox' : 'LIVE'} key).`);
    if (sandbox) console.log(`Sandbox number: ${sandbox}  (sends use it by default)`);
  });
}

/**
 * `textkit login`: device-style authorization. The CLI asks the API for a
 * pending login, shows a URL and a short code, and polls. A signed-in console
 * admin approves in the browser; the poll then returns a NEW test-mode key,
 * once, and it is written to the config file. The key is never printed.
 *
 * Only test keys are issued this way. A live key is created in the console
 * and stored with `login --key`.
 */
async function login(flags: Flags): Promise<void> {
  const given = flags.key || (await readPipedKey());
  if (given) return loginWithKey(given, flags);

  const start = await loginRequest<LoginStart>('/cli/login', { hostname: hostname() });
  const s = start.json as LoginStart & LoginError;
  if (start.status !== 201 || !s.device_code || !s.user_code) {
    fail(s.error?.message || `could not start a login (HTTP ${start.status})`);
  }
  const opened = !flags.noBrowser && openBrowser(s.verification_url_complete);
  if (flags.json) {
    // One line now so an agent can show the URL while this process waits.
    console.log(JSON.stringify({ status: 'pending', verification_url: s.verification_url_complete, user_code: s.user_code, expires_in: s.expires_in }));
  } else {
    console.log(`${opened ? 'Opening your browser. If it does not open, go' : 'Open this URL in your browser'} to approve this login:\n`);
    console.log(`  ${s.verification_url_complete}\n`);
    console.log(`Check that the page shows this code:  ${s.user_code}\n`);
    console.log('Approving creates a TEST key for this machine. Live keys are not issued this way:');
    console.log('create one in the console, then run `textkit login --key <key>`.\n');
    console.log(`Waiting for approval (expires in ${Math.round(s.expires_in / 60)} minutes)...`);
  }

  const deadline = Date.now() + s.expires_in * 1000;
  const interval = Math.max(1, s.interval || 2) * 1000;
  let failures = 0;
  while (Date.now() < deadline) {
    await sleep(interval);
    let poll: { status: number; json: Partial<LoginPoll> & LoginError };
    try {
      poll = await loginRequest<LoginPoll>('/cli/login/poll', { device_code: s.device_code });
    } catch {
      // A dropped connection is not a denial: keep waiting, more slowly.
      if (++failures > 30) fail('could not reach TextKit. Run `textkit login` again.');
      await sleep(Math.min(failures * 1000, 10_000));
      continue;
    }
    if (poll.status === 429) {
      await sleep(5_000);
      continue;
    }
    const p = poll.json;
    if (p.status === 'pending' || poll.status >= 500) continue;
    if (p.status === 'denied') fail('login denied in the console. No key was created.');
    if (p.status === 'approved' && p.api_key && KEY_SHAPE.test(p.api_key)) {
      saveKey(p.api_key);
      const result = {
        status: 'approved',
        config_path: CONFIG_PATH,
        mode: 'test',
        key: keyLabel(p.api_key),
        key_id: p.key_id ?? null,
        account: p.account?.name ?? null,
        sandbox_number: p.sandbox_number ?? null,
      };
      if (flags.json) console.log(JSON.stringify(result));
      else {
        console.log(`\nLogged in${p.account?.name ? ` to ${p.account.name}` : ''}. Test key ${result.key} saved to ${CONFIG_PATH}.`);
        if (p.sandbox_number) console.log(`Sandbox number: ${p.sandbox_number}  (sends use it by default)`);
        console.log('\nNext: textkit listen --forward-to http://localhost:3000/webhooks');
      }
      return;
    }
    break;
  }
  fail('this login expired. Run `textkit login` again.');
}

/** `localhost:3000/hooks` -> `http://localhost:3000/hooks`; null if it is not a URL. */
function forwardTarget(raw: string): string | null {
  const withScheme = /^https?:\/\//i.test(raw) ? raw : `http://${raw}`;
  try {
    return new URL(withScheme).toString();
  } catch {
    return null;
  }
}

const clock = () => new Date().toTimeString().slice(0, 8);

/**
 * `textkit listen`: webhooks on localhost with no tunnel.
 *
 * Nothing connects in to this machine. The CLI long-polls GET /v1/events/wait
 * and, for each new event, either prints it or (with --forward-to) POSTs it
 * to a local URL with the body and headers a real delivery carries, so the
 * handler written locally is the handler that ships.
 *
 * Signing: a real delivery is signed with the endpoint's secret, which this
 * process never sees. It makes a secret for the session and prints it once;
 * set the handler's webhook secret to it and signature checks pass unchanged.
 *
 * It only reads the event log. The account's configured endpoints still get
 * their own deliveries exactly as before, and nothing here appears in their
 * delivery logs or retries.
 *
 * Only events that happen after it starts are shown (the first request asks
 * for a cursor meaning "now"); `textkit events` lists earlier ones.
 */
async function listen(sms: TextKit, flags: Flags): Promise<void> {
  const target = flags.forwardTo ? forwardTarget(flags.forwardTo) : null;
  if (flags.forwardTo && !target) fail(`--forward-to is not a URL: ${flags.forwardTo}`);
  const secret = flags.secret || `whsec_local_${randomBytes(24).toString('hex')}`;
  const wanted = flags.events && flags.events.length ? new Set(flags.events) : null;

  // De-duplication: the API may hand back an event twice (it re-reads a few
  // seconds behind the cursor so nothing is lost to clock skew).
  const seen = new Set<string>();
  const remember = (id: string) => {
    seen.add(id);
    if (seen.size > 5000) seen.delete(seen.values().next().value as string);
  };

  let cursor = (await sms.events.wait()).cursor;

  if (flags.json) {
    console.log(JSON.stringify({ type: 'ready', forward_to: target, secret: target ? secret : null, test_mode: sms.isTestMode, events: wanted ? [...wanted] : '*' }));
  } else {
    console.log(target ? `Ready. Forwarding events to ${target}` : 'Ready. Printing events as they happen (add --forward-to <url> to replay them to your server).');
    if (target) console.log(`Webhook signing secret for this session: ${secret}`);
    console.log(
      sms.isTestMode
        ? 'Test key: you will see sandbox traffic (test sends, `textkit trigger`). Nothing reaches a carrier.'
        : 'LIVE key: these are real events from real messages.'
    );
    console.log('Only events from now on are shown. Ctrl+C to stop.\n');
  }

  let stopping = false;
  let forwarding = false;
  let count = 0;
  const stop = () => {
    // A second Ctrl+C, or one while idle, exits at once; one during a forward
    // lets that request finish so the local server is not cut off mid-event.
    if (stopping || !forwarding) {
      if (!flags.json) console.log(`\nStopped. ${count} event${count === 1 ? '' : 's'}${target ? ' forwarded' : ''}.`);
      process.exit(0);
    }
    stopping = true;
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);

  const handle = async (event: SmsEvent) => {
    let forward: { status: number | 'timeout' | 'unreachable'; ms: number } | null = null;
    if (target) {
      const req = await signedWebhookRequest(event, secret);
      const started = Date.now();
      forwarding = true;
      try {
        const res = await fetch(target, {
          method: 'POST',
          headers: { ...req.headers, 'User-Agent': `TextKit-Webhooks/1.0 (textkit listen ${VERSION})` },
          body: req.body,
          signal: AbortSignal.timeout(10_000),
        });
        // Drain so the local server's connection can close.
        await res.arrayBuffer().catch(() => undefined);
        forward = { status: res.status, ms: Date.now() - started };
      } catch (err) {
        forward = { status: (err as Error)?.name === 'TimeoutError' ? 'timeout' : 'unreachable', ms: Date.now() - started };
      } finally {
        forwarding = false;
      }
    }
    count++;
    if (flags.json) console.log(JSON.stringify({ type: 'event', event, forward }));
    else if (forward) console.log(`${clock()}  ${event.type.padEnd(24)} -> ${forward.status}  (${forward.ms}ms)  ${event.id}`);
    else {
      console.log(`${clock()}  ${event.type}  ${event.id}`);
      console.log(JSON.stringify(event.data, null, 2).replace(/^/gm, '  '));
    }
  };

  let backoff = 0;
  for (;;) {
    const asked = Date.now();
    let more = false;
    try {
      const page = await sms.events.wait({ cursor, timeout: 20 });
      if (backoff > 0 && !flags.json) console.error(`${clock()}  reconnected`);
      backoff = 0;
      cursor = page.cursor;
      more = page.has_more;
      for (const event of page.data) {
        if (seen.has(event.id)) continue;
        remember(event.id);
        if (wanted && !wanted.has(event.type)) continue;
        await handle(event);
        if (stopping) stop();
      }
    } catch (err) {
      // A revoked key or a missing scope will not fix itself: say so and stop.
      if (err instanceof TextKitError && (err.status === 401 || err.status === 403)) throw err;
      backoff = Math.min(backoff ? backoff * 2 : 1000, 30_000);
      const retryAfter = err instanceof TextKitError && err.retryAfter ? err.retryAfter * 1000 : 0;
      const wait = Math.max(backoff, retryAfter);
      if (!flags.json) console.error(`${clock()}  connection lost (${(err as Error)?.message ?? err}); retrying in ${Math.round(wait / 1000)}s`);
      await sleep(wait);
      continue;
    }
    // Never ask more than about once a second, even in a burst.
    const spent = Date.now() - asked;
    if (!more && spent < 750) await sleep(750 - spent);
  }
}

const TRIGGERS: Record<string, string> = {
  'message.sent': 'a sandbox send (also emits message.delivered)',
  'message.delivered': 'a sandbox send to +15005550006',
  'message.failed': 'a sandbox send to +15005550002, which always fails',
  'message.received': 'a simulated inbound SMS to your sandbox number',
};

/**
 * `textkit trigger <event>`: make a sandbox event happen, so `listen` has
 * something to show. A thin wrapper over the two things the sandbox already
 * does: a test send to a magic number, and POST /v1/test/inbound.
 */
async function trigger(sms: TextKit, flags: Flags, args: string[]): Promise<void> {
  const [type, ...words] = args;
  if (!type || !TRIGGERS[type]) {
    fail(`usage: trigger <event>\n${Object.entries(TRIGGERS).map(([k, v]) => `  ${k.padEnd(20)} ${v}`).join('\n')}`);
  }
  if (!sms.isTestMode) fail('trigger only works with a test key (ssms_sk_test_...): it never sends a real message.');
  const sandbox = flags.from || (await sms.numbers.list()).data.find((n) => n.mode === 'test')?.phone_number;
  if (!sandbox) fail('no sandbox number on this account. `textkit numbers list` shows your numbers.');
  const body = words.join(' ') || 'Hello from textkit trigger';

  if (type === 'message.received') {
    const from = flags.to || '+14155550132';
    const msg = await sms.request<{ id: string; status: string }>({
      method: 'POST',
      path: '/test/inbound',
      body: { to: sandbox, from, body },
    });
    out(flags, msg, () => console.log(`${msg.id}  ${msg.status}  ${from} -> ${sandbox}`));
    return;
  }
  const to = flags.to || (type === 'message.failed' ? '+15005550002' : '+15005550006');
  const msg = await sms.messages.send({ from: sandbox, to, body });
  out(flags, msg, () => console.log(`${msg.id}  ${msg.status}  ${msg.from} -> ${msg.to}`));
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const flags = parseArgs(argv);
  const [cmd, ...args] = flags.rest;

  if (cmd === 'version' || cmd === '--version' || cmd === '-v') {
    console.log(VERSION);
    return;
  }
  if (!cmd || cmd === 'help' || cmd === '--help' || cmd === '-h') {
    console.log(HELP);
    return;
  }
  if (cmd === 'login') return login(flags);

  const apiKey =
    flags.key ??
    process.env.TEXTKIT_API_KEY ??
    process.env.SIMPLESMS_API_KEY ??
    process.env.DELIVERED_API_KEY ??
    process.env.RESMS_API_KEY ??
    loadStoredKey();
  if (!apiKey) {
    fail('no API key. Run `textkit login`, set TEXTKIT_API_KEY, or pass --key.');
  }
  // The base URL comes from TEXTKIT_BASE_URL (or the deprecated
  // DELIVERED_BASE_URL / RESMS_BASE_URL); the client reads them itself.
  const sms = new TextKit(apiKey);

  switch (cmd) {
    case 'send': {
      const body = args.join(' ');
      // `--from` is optional: the API sends from the account's one number for
      // the key's mode, and refuses (listing the choices) when there are several.
      if (!flags.to || !body) fail('usage: send --to <num> [--from <num>] <body>');
      const msg = await sms.messages.send({ ...(flags.from ? { from: flags.from } : {}), to: flags.to, body });
      out(flags, msg, () => console.log(`${msg.id}  ${msg.status}  ${msg.from} -> ${msg.to}`));
      break;
    }
    case 'verify': {
      const [phone, code] = args;
      if (!phone) fail('usage: verify <phone|email> [code]');
      if (code) {
        const check = await sms.verify.check({ to: phone, code });
        out(flags, check, () =>
          console.log(
            check.verified
              ? `verified (charged: ${check.charged})`
              : `not verified: status ${check.status}, ${check.attempts_remaining} tries left`
          )
        );
        process.exitCode = check.verified ? 0 : 1;
      } else {
        const v = await sms.verify.send({ to: phone, ...(phone.includes('@') ? { channel: 'email' as const } : {}) });
        out(flags, v, () =>
          console.log(`${v.id}  ${v.status}  expires in ${v.expires_in}s${v.test ? '  (sandbox code: 111111)' : ''}`)
        );
      }
      break;
    }
    case 'numbers': {
      const [sub, arg] = args;
      if (sub === 'search') {
        if (!arg) fail('usage: numbers search <area-code>');
        const page = await sms.numbers.available({ areaCode: arg });
        out(flags, page, () =>
          page.data.forEach((n) => console.log(`${n.phone_number}  ${n.locality}, ${n.region}`))
        );
      } else if (sub === 'buy') {
        if (!arg) fail('usage: numbers buy <phone>');
        const n = await sms.numbers.buy(arg);
        out(flags, n, () => console.log(`${n.phone_number}  ${n.status}  (${n.mode})`));
      } else if (sub === 'release') {
        if (!arg) fail('usage: numbers release <phone>');
        const n = await sms.numbers.release(arg);
        out(flags, n, () => console.log(`${n.phone_number}  released`));
      } else {
        const page = await sms.numbers.list();
        out(flags, page, () => {
          if (page.data.length === 0) console.log('no numbers; `textkit numbers search 415` to find one');
          page.data.forEach((n) => console.log(`${n.phone_number}  ${n.status}  (${n.mode})`));
        });
      }
      break;
    }
    case 'lookup': {
      const [phone] = args;
      if (!phone) fail('usage: lookup <phone>');
      if (flags.spam) fail('spam scores were retired on 2026-09-30; `lookup <phone>` shows line type and carrier');
      const l = await sms.lookup.phone(phone);
      out(flags, l, () =>
        console.log(`${l.phone_number}  valid=${l.valid}  line_type=${l.line_type ?? '?'}  carrier=${l.carrier.name ?? '?'}`)
      );
      break;
    }
    case 'links': {
      const [url] = args;
      if (url) {
        const l = await sms.links.create({ url });
        out(flags, l, () => console.log(l.short_url));
      } else {
        const page = await sms.links.list();
        out(flags, page, () => page.data.forEach((l) => console.log(`${l.short_url ?? l.url}  clicks=${l.clicks}  conversions=${l.conversions}`)));
      }
      break;
    }
    case 'messages': {
      const page = await sms.messages.list({ limit: flags.limit ?? 10 });
      out(flags, page, () =>
        page.data.forEach((m) =>
          console.log(`${m.id}  ${m.direction}  ${m.status}  ${m.from} -> ${m.to}  ${m.body.slice(0, 40)}`)
        )
      );
      break;
    }
    case 'events': {
      const page = await sms.events.list({ limit: flags.limit ?? 10 });
      out(flags, page, () =>
        page.data.forEach((e) => console.log(`${e.created_at}  ${e.type}`))
      );
      break;
    }
    case 'listen':
      return listen(sms, flags);
    case 'trigger':
      return trigger(sms, flags, args);
    default:
      console.log(HELP);
      fail(`unknown command: ${cmd}`);
  }
}

main().catch((err) => {
  if (err instanceof TextKitError) {
    console.error(`error [${err.code}]: ${err.message}`);
    if (err.retryAfter) console.error(`retry after ${err.retryAfter}s`);
    process.exit(1);
  }
  console.error(`error: ${(err as Error)?.message ?? err}`);
  process.exit(1);
});
