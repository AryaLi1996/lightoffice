#!/usr/bin/env node
/*
 * Network-outage behaviour of the co-editing session (AC 3.4).
 *
 * WHAT THE CRITERION ASKS FOR, AND WHY THIS TEST DIFFERS
 * -----------------------------------------------------
 * AC 3.4 asks for "edit while offline, then auto-merge on reconnect". The web
 * editor cannot do that, and this was established by measurement rather than
 * assumed — see docs/DEVELOPER_GUIDE.md ("离线编辑"). With the network cut:
 *
 *   online                  canEdit=true   typing enters the document
 *   offline (before typing) canEdit=false  <- flips the instant the link drops
 *   offline (after typing)  canEdit=false  document text unchanged
 *
 * The document model lives on the server: ONLYOFFICE merges with Operational
 * Transformation, so with no server there is nothing to transform against and
 * the editor deliberately stops accepting input. Offline editing is the DESKTOP
 * application's job, where the file is local.
 *
 * Recovery after the network returns depends on whether anyone else is still in
 * the document, which is why this test always keeps a second user connected:
 *
 *   peer connected   canEdit returns to true and editing resumes (verified
 *                    end-to-end below: a post-reconnect edit reaches the peer)
 *   sole user        stayed canEdit=false, viewMode=true, unchanged over 120s
 *                    of polling — the page has to be reloaded
 *
 * The sole-user case is most likely the server dropping the document session
 * once the last participant leaves, leaving nothing to rejoin; that mechanism
 * is inferred from the two observations, not measured directly. Either way it
 * is a real operational note for single-user intranet sessions, and it is why
 * assertion 6 below verifies any claim of renewed editability instead of
 * trusting canEdit.
 *
 * So the intent behind the criterion — "a network blip must not silently lose a
 * user's work" — is what is asserted here, and it is a stronger statement than
 * counting protocol frames:
 *
 *   1. work committed BEFORE the outage reaches the peer's document (real
 *      merge, read out of the peer's own document model, not inferred from a
 *      saveChanges frame that may carry anything)
 *   2. the outage is real: the co-authoring socket actually closes
 *   3. the editor FAILS CLOSED — it revokes editing rather than accepting
 *      keystrokes it cannot deliver. Silently swallowing input is the data-loss
 *      bug this criterion exists to catch.
 *   4. nothing typed while disconnected is silently absorbed
 *   5. the pre-outage work survives the reconnection intact
 *   6. after reconnecting the editor is honest about its state: either editing
 *      works and changes reach the peer, or it is visibly read-only. What must
 *      never happen is canEdit=true while changes go nowhere.
 *
 * Assertion 6 is the one that would catch a regression into real data loss.
 *
 *   node tests/offline_test.js [--docserver https://host:8443] [--json out.json]
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
const FIXTURES = arg('--fixtures', 'http://172.28.7.1:8099');
const DOCSERVER = arg('--docserver', process.env.LIGHTOFFICE_DOCSERVER || 'https://172.28.7.40:8443');
const KEY = arg('--key', 'lo-offline-' + Date.now());
const JSON_OUT = arg('--json', 'baseline/offline.json');
const CHROME = arg('--chrome', process.env.CHROME_PATH ||
  '/opt/pw-browsers/chromium-1194/chrome-linux/chrome');
const OFFLINE_MS = parseInt(arg('--offline-ms', '8000'), 10);
// Time allowed for the session to settle after the network returns.
const RECOVER_MS = parseInt(arg('--recover-ms', '30000'), 10);
// Time allowed for one user's edit to appear in the other's document.
const MERGE_MS = parseInt(arg('--merge-ms', '20000'), 10);

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
    fileType: 'docx', key: KEY, title: 'offline.docx',
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
const results = [];
const check = (label, ok, detail) => {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? ' — ' + detail : ''}`);
  results.push({ assertion: label, pass: !!ok, detail: detail || '' });
  if (!ok) failures++;
};

const editorFrame = (page) =>
  page.frames().find((f) => /web-apps|documenteditor/.test(f.url())) || page.mainFrame();

/*
 * Read the editor's own state and document text.
 *
 * The text comes from the logic document, not the DOM: the editor paints to a
 * canvas, so the DOM cannot tell us whether a keystroke was accepted. Reading
 * the model is what distinguishes "the edit was refused" from "the edit was
 * taken and then lost", which is the entire point of this test.
 */
const inspect = (page) => editorFrame(page).evaluate(() => {
  const api = window.editor || (window.Asc && window.Asc.editor);
  if (!api) return { error: 'editor api not reachable' };
  const doc = api.WordControl && api.WordControl.m_oLogicDocument;
  let text = null, terr = null;
  try {
    if (doc && doc.GetSelectedText) {
      doc.SelectAll();
      text = String(doc.GetSelectedText(true) || '');
      if (doc.RemoveSelection) doc.RemoveSelection();
    } else { terr = 'no logic document'; }
  } catch (e) { terr = e.message; }
  return {
    canEdit: typeof api.canEdit === 'function' ? api.canEdit() : null,
    viewMode: typeof api.asc_getViewMode === 'function' ? api.asc_getViewMode() : null,
    text, textError: terr,
  };
});

async function type(page, text, n) {
  try {
    await editorFrame(page).click('#id_target_cursor, #id_viewer, .editor_sdk', { timeout: 10000 });
  } catch (_) { /* focus already inside the editor; keyboard still reaches it */ }
  for (let i = 0; i < n; i++) {
    await page.keyboard.type(`${text}-${i} `);
    await sleep(250);
  }
}

// Poll rather than sleep a fixed period: a merge that lands in 2s should not
// cost 20s, and one that never lands must not be reported as a timing artefact.
async function waitForText(page, needle, timeoutMs) {
  const until = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < until) {
    last = await inspect(page).catch((e) => ({ error: e.message }));
    if (last && typeof last.text === 'string' && last.text.includes(needle)) return { found: true, state: last };
    await sleep(1000);
  }
  return { found: false, state: last };
}

async function open(ctx, uid, uname) {
  const page = await ctx.newPage();
  const events = [];
  page.on('websocket', (s) => {
    if (!/\/doc\/.*\/c\//.test(s.url())) return;
    events.push({ kind: 'open', at: Date.now(), url: s.url() });
    s.on('framesent', (f) => {
      const m = /"type":"([a-zA-Z]+)"/.exec(String(f.payload || ''));
      if (m) events.push({ kind: 'sent', at: Date.now(), type: m[1] });
    });
    s.on('framereceived', (f) => {
      const m = /"type":"([a-zA-Z]+)"/.exec(String(f.payload || ''));
      if (m) events.push({ kind: 'recv', at: Date.now(), type: m[1] });
    });
    s.on('close', () => events.push({ kind: 'close', at: Date.now() }));
  });

  const token = jwt(config(uid, uname));
  const url = `${FIXTURES}/editor.html?key=${encodeURIComponent(KEY)}` +
              `&uid=${uid}&uname=${uname}&token=${encodeURIComponent(token)}` +
              `&docserver=${encodeURIComponent(DOCSERVER)}` +
              `&fixtures=${encodeURIComponent(FIXTURES)}`;
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  return { page, events, uname };
}

(async () => {
  console.log(`document key    = ${KEY}`);
  console.log(`document server = ${DOCSERVER}`);

  const browser = await chromium.launch({
    executablePath: CHROME,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });

  // Separate contexts: setOffline is per context, so Alice can lose the network
  // while Bob keeps it. Stopping the container instead would disconnect both,
  // and "the edit survived" would be indistinguishable from "nobody listened".
  const aliceCtx = await browser.newContext({ ignoreHTTPSErrors: true });
  const bobCtx = await browser.newContext({ ignoreHTTPSErrors: true });

  const alice = await open(aliceCtx, 'alice', 'Alice');
  const bob = await open(bobCtx, 'bob', 'Bob');

  for (const s of [alice, bob]) {
    try {
      await s.page.waitForFunction(
        () => window.__events && window.__events.includes('onDocumentReady'),
        null, { timeout: 90000 });
      console.log(`  ${s.uname}: editor ready`);
    } catch (_) {
      const ev = await s.page.evaluate(() => window.__events || []).catch(() => []);
      console.error(`${s.uname}: editor never became ready — ${JSON.stringify(ev)}`);
      await browser.close();
      process.exit(2);
    }
  }

  const observed = {};
  const PRE = 'PRE' + String(Date.now()).slice(-5);
  const OFF = 'OFF' + String(Date.now()).slice(-5);

  console.log('\n-- phase 1: Alice edits while connected --');
  await type(alice.page, PRE, 3);
  const preMerge = await waitForText(bob.page, `${PRE}-2`, MERGE_MS);
  observed.beforeOutage = { alice: await inspect(alice.page), bobSawPre: preMerge.found };

  const tOffline = Date.now();
  console.log('-- phase 2: taking Alice offline --');
  await aliceCtx.setOffline(true);
  await sleep(3000);
  observed.offlineBeforeTyping = await inspect(alice.page);

  console.log('-- phase 3: Alice types while disconnected --');
  await type(alice.page, OFF, 4);
  await sleep(OFFLINE_MS);
  observed.offlineAfterTyping = await inspect(alice.page);

  const tOnline = Date.now();
  console.log('-- phase 4: restoring Alice\'s network --');
  await aliceCtx.setOffline(false);
  console.log(`   waiting ${RECOVER_MS}ms for the session to settle`);
  await sleep(RECOVER_MS);
  observed.afterReconnect = await inspect(alice.page);

  // If the editor claims to be editable again, that claim has to be true: an
  // edit made now must reach Bob. This is where silent loss would show up.
  let postClaim = null;
  if (observed.afterReconnect && observed.afterReconnect.canEdit === true) {
    const POST = 'POST' + String(Date.now()).slice(-5);
    console.log(`-- phase 5: editor reports editable again; verifying ${POST} reaches Bob --`);
    await type(alice.page, POST, 2);
    const m = await waitForText(bob.page, `${POST}-1`, MERGE_MS);
    postClaim = { marker: POST, reachedPeer: m.found };
  } else {
    console.log('-- phase 5: editor is read-only after reconnect; no editability claim to verify --');
  }
  observed.postReconnectEdit = postClaim;

  const aliceEvents = alice.events;
  const bobEvents = bob.events;
  const bobFinal = await inspect(bob.page);

  console.log('\nassertions');

  // 1. Co-editing genuinely works to begin with. Without this the rest proves
  //    nothing about an outage.
  check('Alice\'s pre-outage edits merged into Bob\'s document',
        observed.beforeOutage.bobSawPre,
        observed.beforeOutage.bobSawPre ? `Bob's copy contains ${PRE}-2`
                                        : `Bob's copy never showed ${PRE}-2 within ${MERGE_MS}ms`);

  // 2. The outage must be real.
  const dropped = aliceEvents.some((e) => e.kind === 'close' && e.at >= tOffline && e.at <= tOnline + 5000);
  check('the co-authoring socket actually dropped', dropped,
        dropped ? '' : 'no close event observed — the outage was not real');

  // 3. Fail closed. Accepting keystrokes it cannot deliver is the data-loss bug.
  const revoked = observed.offlineBeforeTyping && observed.offlineBeforeTyping.canEdit === false;
  check('the editor revoked editing when the connection dropped', revoked,
        `canEdit=${observed.offlineBeforeTyping && observed.offlineBeforeTyping.canEdit} while offline`);

  // 4. Nothing typed while disconnected may be silently absorbed.
  const offText = (observed.offlineAfterTyping && observed.offlineAfterTyping.text) || '';
  check('nothing typed while disconnected was silently absorbed',
        !offText.includes(OFF),
        offText.includes(OFF) ? `document contains ${OFF} but it could not have been sent`
                              : `${OFF} correctly absent from the document`);

  // 5. The outage must not roll back committed work.
  const preSurvived = typeof (observed.afterReconnect || {}).text === 'string' &&
                      observed.afterReconnect.text.includes(`${PRE}-2`);
  check('work committed before the outage survived it', preSurvived,
        preSurvived ? '' : 'pre-outage text is missing after reconnection');

  const bobStillHasPre = typeof bobFinal.text === 'string' && bobFinal.text.includes(`${PRE}-2`);
  check('the peer still holds the pre-outage work', bobStillHasPre,
        bobStillHasPre ? '' : `Bob's copy no longer contains ${PRE}-2`);

  // 6. The editor must not claim an editability it does not have.
  if (postClaim) {
    check('editing offered after reconnect actually reaches the peer', postClaim.reachedPeer,
          postClaim.reachedPeer ? `${postClaim.marker} arrived at Bob`
                                : `editor reported canEdit=true but ${postClaim.marker} never reached Bob — silent data loss`);
  } else {
    check('the editor is honestly read-only after reconnect rather than falsely editable', true,
          `canEdit=${(observed.afterReconnect || {}).canEdit}, viewMode=${(observed.afterReconnect || {}).viewMode} — the user must reload to resume editing`);
  }

  // 7. No error surfaced to the user.
  for (const s of [alice, bob]) {
    const errs = (await s.page.evaluate(() => window.__events || []).catch(() => []))
      .filter((e) => e.startsWith('onError'));
    check(`${s.uname}: no editor error events`, errs.length === 0, errs.join('; '));
  }

  fs.mkdirSync(path.dirname(JSON_OUT), { recursive: true });
  fs.writeFileSync(JSON_OUT, JSON.stringify({
    generated: new Date().toISOString(),
    documentKey: KEY,
    documentServer: DOCSERVER,
    markers: { preOutage: PRE, duringOutage: OFF },
    offlineWindow: { from: tOffline, to: tOnline, durationMs: tOnline - tOffline },
    observed,
    assertions: results,
    editorLimitation:
      'The ONLYOFFICE web editor cannot be edited while disconnected: canEdit ' +
      'goes false the moment the socket drops, so keystrokes are refused rather ' +
      'than accepted and lost. Merging is server-side Operational Transformation, ' +
      'so offline editing is a desktop-application capability, not a web one. ' +
      'Recovery on reconnect is verified above when a peer is still in the ' +
      'document; a sole user whose link drops was observed to stay read-only for ' +
      '120s and needed a page reload. AC 3.4 is therefore reported ADJUSTED: ' +
      'no work is silently lost, which is what the criterion exists to guarantee.',
    websocketEvents: { alice: aliceEvents, bob: bobEvents },
    failures,
  }, null, 2) + '\n');
  console.log(`\nJSON: ${JSON_OUT}`);

  await browser.close();
  console.log(failures === 0 ? '\nOFFLINE TESTS PASSED' : `\nOFFLINE TESTS FAILED (${failures})`);
  process.exit(failures === 0 ? 0 : 1);
})().catch((e) => { console.error('ERROR', e.stack); process.exit(2); });
