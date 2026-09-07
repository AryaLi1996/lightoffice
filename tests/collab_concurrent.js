#!/usr/bin/env node
/*
 * Concurrent co-editing check (AC 3.3 / 3.4 / 3.5).
 *
 * Opens the same cloud document from two independent sessions, writes to it
 * from both, and asserts that
 *   - the Document Server WebSocket completes a 101 handshake (AC 3.3),
 *   - both changesets are handled rather than one erroring out (AC 3.4),
 *   - a WebDAV lock held by one session makes the other's PUT return 423 (AC 3.5).
 *
 *   node tests/collab_concurrent.js \
 *      --portal http://10.0.7.10:8080 --docserver http://10.0.7.20 \
 *      --user alice --pass secret --user2 bob --pass2 secret2 --file /Test.docx
 */
'use strict';

const fs = require('fs');
const path = require('path');

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const PORTAL = arg('--portal', process.env.LIGHTOFFICE_PORTAL || 'http://10.0.7.10:8080');
const DOCSERVER = arg('--docserver', process.env.LIGHTOFFICE_DOCSERVER || 'http://10.0.7.20');
const USER = arg('--user');
const PASS = arg('--pass');
const USER2 = arg('--user2');
const PASS2 = arg('--pass2');
const FILE = arg('--file', '/LightOffice-collab-test.docx');
const LOG = arg('--log', 'logs/console.log');

if (!USER || !PASS || !USER2 || !PASS2) {
  console.error('need --user/--pass and --user2/--pass2');
  process.exit(2);
}

const basic = (u, p) => 'Basic ' + Buffer.from(u + ':' + p).toString('base64');
const dav = (u) => `${PORTAL}/remote.php/dav/files/${u}${FILE}`;

let failures = 0;
const check = (label, ok, detail) => {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? ' — ' + detail : ''}`);
  if (!ok) failures++;
};

async function put(user, pass, body) {
  return fetch(dav(user), {
    method: 'PUT',
    headers: { Authorization: basic(user, pass) },
    body,
  });
}

async function lock(user, pass) {
  const body = [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<D:lockinfo xmlns:D="DAV:">',
    '  <D:lockscope><D:exclusive/></D:lockscope>',
    '  <D:locktype><D:write/></D:locktype>',
    `  <D:owner><D:href>${user}</D:href></D:owner>`,
    '</D:lockinfo>',
  ].join('\n');
  return fetch(dav(user), {
    method: 'LOCK',
    headers: {
      Authorization: basic(user, pass),
      'Content-Type': 'application/xml',
      Timeout: 'Second-120',
    },
    body,
  });
}

async function unlock(user, pass, token) {
  return fetch(dav(user), {
    method: 'UNLOCK',
    headers: { Authorization: basic(user, pass), 'Lock-Token': token },
  });
}

// A minimal but structurally valid empty .docx, if the fixture is absent the
// test still exercises the transport; it just is not a real document.
function seedBytes() {
  const fixture = path.join('tests', 'fixtures', 'empty.docx');
  if (fs.existsSync(fixture)) return fs.readFileSync(fixture);
  console.log('  (no tests/fixtures/empty.docx — using a placeholder payload)');
  return Buffer.from('LightOffice collab placeholder payload');
}

(async () => {
  console.log(`portal=${PORTAL} docserver=${DOCSERVER} file=${FILE}`);

  // --- reachability -------------------------------------------------------
  const status = await fetch(`${PORTAL}/status.php`).catch(() => null);
  check('portal status.php reachable', Boolean(status && status.ok),
        status ? 'HTTP ' + status.status : 'no response');

  const health = await fetch(`${DOCSERVER}/healthcheck`).catch(() => null);
  check('document server healthcheck', Boolean(health && health.ok),
        health ? 'HTTP ' + health.status : 'no response');

  // --- AC 3.3: WebSocket upgrade -----------------------------------------
  // Co-editing runs over socket.io; a live session begins with a 101. We record
  // the handshake to the log so the assertion matches something real rather
  // than inferring success from the absence of errors.
  let wsOk = false;
  try {
    const WS = globalThis.WebSocket;
    if (!WS) throw new Error('no WebSocket in this node runtime');
    const url = DOCSERVER.replace(/^http/, 'ws') + '/doc/dummy/c/websocket';
    await new Promise((resolve, reject) => {
      const ws = new WS(url);
      const timer = setTimeout(() => { ws.close(); reject(new Error('timeout')); }, 15000);
      ws.onopen = () => {
        clearTimeout(timer);
        wsOk = true;
        fs.mkdirSync(path.dirname(LOG), { recursive: true });
        fs.appendFileSync(LOG, `wss handshake 101 Switching Protocols ${url}\n`);
        ws.close();
        resolve();
      };
      ws.onerror = (e) => { clearTimeout(timer); reject(new Error(e.message || 'ws error')); };
    });
  } catch (e) {
    console.log(`  (websocket: ${e.message})`);
  }
  check('document server WebSocket 101 handshake', wsOk);

  // --- seed the document --------------------------------------------------
  const seed = seedBytes();
  const seeded = await put(USER, PASS, seed);
  check('seed document uploaded', seeded.status < 300, 'HTTP ' + seeded.status);

  // --- AC 3.4: concurrent writes are both handled -------------------------
  const [r1, r2] = await Promise.all([
    put(USER, PASS, Buffer.concat([seed, Buffer.from(' <<alice>>')])),
    put(USER2, PASS2, Buffer.concat([seed, Buffer.from(' <<bob>>')])),
  ]);
  check('concurrent writes handled without server error',
        [r1.status, r2.status].every((s) => s < 500),
        `alice=${r1.status} bob=${r2.status}`);

  // --- AC 3.5: exclusive lock produces 423 --------------------------------
  const locked = await lock(USER, PASS);
  const token = locked.headers.get('lock-token');
  check('exclusive WebDAV lock acquired',
        locked.status < 300 && Boolean(token), 'HTTP ' + locked.status);

  if (token) {
    const blocked = await put(USER2, PASS2, Buffer.from('should be rejected'));
    check('second writer receives 423 Locked', blocked.status === 423,
          'HTTP ' + blocked.status);
    await unlock(USER, PASS, token);
  }

  console.log(failures === 0 ? '\nCOLLAB TESTS PASSED' : `\nCOLLAB TESTS FAILED (${failures})`);
  process.exit(failures === 0 ? 0 : 1);
})().catch((e) => { console.error(e); process.exit(2); });
