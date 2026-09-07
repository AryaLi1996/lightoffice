#!/usr/bin/env node
/*
 * Real two-user co-editing check (AC 3.3 / 3.4).
 *
 * Rather than hand-rolling the Document Server's co-authoring protocol, this
 * loads the server's own api.js in two headless Chromium contexts — the same
 * editor code a user runs — points both at one document key, types into both,
 * and inspects the WebSocket frames they exchange.
 *
 * That makes the assertions structural rather than cosmetic:
 *   - the co-authoring socket completes a 101 upgrade                  (AC 3.3)
 *   - both sessions reach onDocumentReady on the same document key
 *   - each editor RECEIVES the other's `saveChanges`, i.e. concurrent
 *     changesets are merged and broadcast rather than one silently winning
 *   - cursor positions are exchanged both ways                         (AC 3.4)
 *
 * Prerequisites: deploy/docker-compose.nextcloud.yml is up, and
 * tests/fixture_server.js is serving tests/fixtures on 10.0.7.1:8099.
 *
 *   node tests/coedit_browser.js [--docserver http://10.0.7.20] [--json out.json]
 */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const SECRET = process.env.JWT_SECRET || arg('--secret', 'lightoffice_jwt_secret');
const FIXTURES = arg('--fixtures', 'http://10.0.7.1:8099');
const KEY = arg('--key', 'lo-coedit-' + Date.now());
const JSON_OUT = arg('--json', 'baseline/coedit.json');
const CHROME = arg('--chrome', process.env.CHROME_PATH ||
  '/opt/pw-browsers/chromium-1194/chrome-linux/chrome');

let chromium;
try { ({ chromium } = require('playwright')); }
catch (_) {
  try { ({ chromium } = require('/tmp/node_modules/playwright')); }
  catch (e) { console.error('playwright is not installed: npm i -D playwright'); process.exit(2); }
}

function jwt(payload) {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const h = b64({ alg: 'HS256', typ: 'JWT' });
  const b = b64(payload);
  const s = crypto.createHmac('sha256', SECRET).update(h + '.' + b).digest('base64url');
  return h + '.' + b + '.' + s;
}

const config = (uid, uname) => ({
  document: {
    fileType: 'docx', key: KEY, title: 'collab.docx',
    url: `${FIXTURES}/collab.docx`,
    permissions: { edit: true, download: true },
  },
  documentType: 'word',
  editorConfig: {
    mode: 'edit', lang: 'en',
    callbackUrl: `${FIXTURES}/callback`,
    user: { id: uid, name: uname },
    customization: { autosave: true, forcesave: false },
  },
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let failures = 0;
const check = (label, ok, detail) => {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? ' — ' + detail : ''}`);
  if (!ok) failures++;
};

async function open(browser, uid, uname) {
  const page = await (await browser.newContext()).newPage();
  const sockets = [];
  page.on('websocket', (s) => {
    const rec = { url: s.url(), sent: 0, received: 0, sentTypes: new Set(), recvTypes: new Set() };
    sockets.push(rec);
    const typeOf = (f) => {
      const m = /"type":"([a-zA-Z]+)"/.exec(String(f.payload || ''));
      return m ? m[1] : null;
    };
    s.on('framesent', (f) => { rec.sent++; const t = typeOf(f); if (t) rec.sentTypes.add(t); });
    s.on('framereceived', (f) => { rec.received++; const t = typeOf(f); if (t) rec.recvTypes.add(t); });
  });

  const token = jwt(config(uid, uname));
  const url = `${FIXTURES}/editor.html?key=${encodeURIComponent(KEY)}` +
              `&uid=${uid}&uname=${uname}&token=${encodeURIComponent(token)}`;
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  return { page, sockets, uname };
}

(async () => {
  console.log(`document key = ${KEY}`);
  const browser = await chromium.launch({
    executablePath: CHROME,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });

  const alice = await open(browser, 'alice', 'Alice');
  const bob = await open(browser, 'bob', 'Bob');
  const both = [alice, bob];

  for (const s of both) {
    try {
      await s.page.waitForFunction(
        () => window.__events && window.__events.includes('onDocumentReady'),
        null, { timeout: 90000 });
      check(`${s.uname}: editor reached onDocumentReady`, true);
    } catch (_) {
      check(`${s.uname}: editor reached onDocumentReady`, false, 'timed out');
    }
  }

  // Concurrent typing into the same document, at deliberately different
  // cadences so the two changeset streams genuinely interleave.
  await Promise.all(both.map(async (s, i) => {
    try {
      const frame = s.page.frames().find((f) => /web-apps|documenteditor/.test(f.url())) || s.page.mainFrame();
      await frame.click('#id_target_cursor, #id_viewer, .editor_sdk', { timeout: 15000 });
    } catch (_) { /* typing without an explicit focus click still reaches the editor */ }
    for (let n = 0; n < 8; n++) {
      await s.page.keyboard.type(`${s.uname}-${n} `);
      await sleep(200 + i * 90);
    }
  }));

  await sleep(6000);

  const summary = {};
  for (const s of both) {
    const events = await s.page.evaluate(() => window.__events || []);
    const ws = s.sockets.map((w) => ({
      url: w.url, sent: w.sent, received: w.received,
      sentTypes: [...w.sentTypes].sort(), recvTypes: [...w.recvTypes].sort(),
    }));
    summary[s.uname] = { events, websockets: ws };
  }

  console.log('\nassertions');

  // AC 3.3 — the co-authoring socket exists and carried traffic. Playwright only
  // surfaces a websocket object once the 101 upgrade has completed.
  for (const s of both) {
    const w = summary[s.uname].websockets.find((x) => /\/doc\/.*\/c\//.test(x.url));
    check(`${s.uname}: co-authoring WebSocket upgraded (101) and active`,
          Boolean(w && w.sent > 0 && w.received > 0),
          w ? `sent=${w.sent} received=${w.received}` : 'no co-authoring socket');
  }

  // AC 3.4 — each editor must RECEIVE the other's changeset, not just send one.
  for (const s of both) {
    const w = summary[s.uname].websockets.find((x) => /\/doc\/.*\/c\//.test(x.url)) || { sentTypes: [], recvTypes: [] };
    check(`${s.uname}: sent its own changeset`, w.sentTypes.includes('saveChanges'));
    check(`${s.uname}: received the other user's changeset`,
          w.recvTypes.includes('saveChanges'),
          `received types: ${w.recvTypes.join(' ')}`);
    check(`${s.uname}: cursor position exchanged both ways`,
          w.sentTypes.includes('cursor') && w.recvTypes.includes('cursor'));
  }

  for (const s of both) {
    const errs = summary[s.uname].events.filter((e) => e.startsWith('onError'));
    check(`${s.uname}: no editor error events`, errs.length === 0, errs.join('; '));
  }

  fs.mkdirSync(path.dirname(JSON_OUT), { recursive: true });
  fs.writeFileSync(JSON_OUT, JSON.stringify({
    generated: new Date().toISOString(),
    documentKey: KEY,
    sessions: summary,
    failures,
  }, null, 2) + '\n');
  console.log(`\nJSON: ${JSON_OUT}`);

  await browser.close();
  console.log(failures === 0 ? '\nCO-EDITING TESTS PASSED' : `\nCO-EDITING TESTS FAILED (${failures})`);
  process.exit(failures === 0 ? 0 : 1);
})().catch((e) => { console.error('ERROR', e.message); process.exit(2); });
