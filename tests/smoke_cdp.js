#!/usr/bin/env node
/*
 * LightOffice desktop smoke test (AC 5.3).
 *
 * The editors run inside CEF, so we drive them over the Chrome DevTools
 * Protocol rather than launching a browser: start the app with a fixed
 * --remote-debugging-port, attach Playwright to it, then exercise
 * new document -> type -> save and confirm a .docx lands on disk.
 *
 *   node tests/smoke_cdp.js --app /path/to/DesktopEditors [--port 9222]
 *
 * Exits 0 on success, 1 on assertion failure, 2 if the app could not be
 * started or attached to.
 */
'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const APP = arg('--app', process.env.LIGHTOFFICE_APP);
const PORT = parseInt(arg('--port', '9222'), 10);
const TIMEOUT = parseInt(arg('--timeout', '120000'), 10);

if (!APP) {
  console.error('usage: node tests/smoke_cdp.js --app /path/to/DesktopEditors');
  process.exit(2);
}
if (!fs.existsSync(APP)) {
  console.error(`app not found: ${APP}`);
  process.exit(2);
}

let chromium;
try {
  ({ chromium } = require('playwright'));
} catch (e) {
  console.error('playwright is not installed: npm i -D playwright');
  process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForDebugger(port, deadline) {
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (res.ok) return await res.json();
    } catch (_) { /* not up yet */ }
    await sleep(500);
  }
  throw new Error(`CDP endpoint never came up on :${port}`);
}

(async () => {
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'lightoffice-smoke-'));
  const deadline = Date.now() + TIMEOUT;
  let failures = 0;
  const check = (label, ok) => {
    console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}`);
    if (!ok) failures++;
  };

  console.log(`launching ${APP} (CDP :${PORT}, workdir ${outDir})`);
  const app = spawn(APP, [`--remote-debugging-port=${PORT}`, '--no-sandbox'], {
    cwd: outDir,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, LD_LIBRARY_PATH: path.dirname(APP) },
  });
  app.on('error', (e) => { console.error('spawn failed:', e.message); process.exit(2); });

  let browser;
  try {
    const version = await waitForDebugger(PORT, deadline);
    console.log(`attached: ${version.Browser}`);
    browser = await chromium.connectOverCDP(`http://127.0.0.1:${PORT}`);

    // The start page is the first context; a new document opens another target.
    const ctx = browser.contexts()[0];
    let page = ctx.pages()[0] || (await ctx.waitForEvent('page', { timeout: 30000 }));
    await page.waitForLoadState('domcontentloaded');

    // New text document. The start page exposes these as data-action links.
    const newDoc = page.locator('[data-action="new-document"], .app-item.document').first();
    if (await newDoc.count()) {
      const opened = ctx.waitForEvent('page', { timeout: 60000 });
      await newDoc.click();
      page = await opened;
      await page.waitForLoadState('domcontentloaded');
    }

    // AC 5.3: the editor surface must exist.
    const editor = page.locator('#id_main_editor, #editor_sdk').first();
    await editor.waitFor({ state: 'attached', timeout: 60000 });
    check('editor surface present (#id_main_editor / #editor_sdk)', await editor.count() > 0);

    // Type into the canvas.
    await page.keyboard.type('LightOffice smoke test 冒烟测试');
    await sleep(1000);

    // Save. Ctrl+S in the desktop build writes without a dialog once the
    // document has a path; for an unsaved doc the shell supplies one.
    const before = new Set(fs.readdirSync(outDir));
    await page.keyboard.press('Control+S');

    let saved = null;
    while (Date.now() < deadline && !saved) {
      await sleep(1000);
      saved = fs.readdirSync(outDir)
        .filter((f) => f.endsWith('.docx') && !before.has(f))[0] || null;
    }
    check('a new .docx was written on save', Boolean(saved));
    if (saved) {
      const size = fs.statSync(path.join(outDir, saved)).size;
      check(`saved file is non-trivial (${size} bytes > 4096)`, size > 4096);
    }
  } catch (err) {
    console.error(`smoke test error: ${err.message}`);
    failures++;
  } finally {
    if (browser) await browser.close().catch(() => {});
    app.kill('SIGTERM');
    await sleep(1000);
    if (!app.killed) app.kill('SIGKILL');
  }

  console.log(failures === 0 ? '\nSMOKE TEST PASSED' : `\nSMOKE TEST FAILED (${failures})`);
  process.exit(failures === 0 ? 0 : 1);
})();
