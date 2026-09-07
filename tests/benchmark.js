#!/usr/bin/env node
/*
 * Cold-start and peak-memory benchmark (AC 4.4 / 4.5).
 *
 * Compares an optimised LightOffice build against a stock ONLYOFFICE build:
 *   - cold start   = process spawn -> main window loaded, must be < 80% of baseline
 *   - peak memory  = Max RSS from /usr/bin/time -v, must be < 85% of baseline
 *
 * "Main window loaded" is taken from the CDP endpoint becoming answerable, which
 * is the first moment the editor shell is actually usable — a plain "process
 * exists" timer would report a number that has nothing to do with what a user
 * waits for. Each build is run --runs times and the median is used, because
 * first-run page cache effects otherwise dominate the comparison.
 *
 *   node tests/benchmark.js \
 *      --baseline /path/to/stock/DesktopEditors \
 *      --candidate /path/to/lightoffice/DesktopEditors \
 *      [--runs 5] [--port 9333] [--json baseline/benchmark.json]
 */
'use strict';

const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const BASELINE = arg('--baseline');
const CANDIDATE = arg('--candidate');
const RUNS = parseInt(arg('--runs', '5'), 10);
const PORT = parseInt(arg('--port', '9333'), 10);
const JSON_OUT = arg('--json', 'baseline/benchmark.json');
const TIMEOUT = parseInt(arg('--timeout', '120000'), 10);

if (!BASELINE || !CANDIDATE) {
  console.error('usage: node tests/benchmark.js --baseline <bin> --candidate <bin> [--runs N]');
  process.exit(2);
}
for (const p of [BASELINE, CANDIDATE]) {
  if (!fs.existsSync(p)) { console.error(`not found: ${p}`); process.exit(2); }
}
if (!fs.existsSync('/usr/bin/time')) {
  console.error('/usr/bin/time is required for Max RSS (apt install time)');
  process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

async function waitForWindow(port, deadline) {
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/list`);
      if (res.ok) {
        const targets = await res.json();
        if (targets.some((t) => t.type === 'page')) return true;
      }
    } catch (_) { /* not up yet */ }
    await sleep(25);
  }
  return false;
}

// Drop the page cache between runs so "cold" actually means cold. Needs root;
// without it the first run is cold and the rest are warm, which flatters
// whichever build happens to run second.
function dropCaches() {
  const r = spawnSync('sh', ['-c', 'sync && echo 3 > /proc/sys/vm/drop_caches'], { stdio: 'ignore' });
  return r.status === 0;
}

async function measure(bin, label, run) {
  const rssFile = path.join(os.tmpdir(), `lo-rss-${process.pid}-${run}.txt`);
  const cold = dropCaches();
  const started = Date.now();

  const proc = spawn('/usr/bin/time', [
    '-v', '-o', rssFile,
    bin, `--remote-debugging-port=${PORT}`, '--no-sandbox',
  ], {
    stdio: 'ignore',
    env: { ...process.env, LD_LIBRARY_PATH: path.dirname(bin) },
  });

  const ok = await waitForWindow(PORT, started + TIMEOUT);
  const elapsed = Date.now() - started;

  proc.kill('SIGTERM');
  await sleep(1500);
  if (!proc.killed) proc.kill('SIGKILL');
  await sleep(500);

  let rssKb = null;
  try {
    const m = fs.readFileSync(rssFile, 'utf8')
      .match(/Maximum resident set size \(kbytes\):\s*(\d+)/);
    if (m) rssKb = parseInt(m[1], 10);
  } catch (_) { /* time output missing */ }
  fs.rmSync(rssFile, { force: true });

  console.log(`  ${label} run ${run + 1}/${RUNS}: ` +
    `${ok ? elapsed + ' ms' : 'TIMEOUT'}` +
    `${rssKb ? `, maxRSS ${(rssKb / 1024).toFixed(1)} MiB` : ''}` +
    `${cold ? '' : ' (page cache not dropped — run as root for true cold start)'}`);

  return ok ? { ms: elapsed, rssKb } : null;
}

(async () => {
  const results = {};
  for (const [label, bin] of [['baseline', BASELINE], ['candidate', CANDIDATE]]) {
    console.log(`\nmeasuring ${label}: ${bin}`);
    const samples = [];
    for (let i = 0; i < RUNS; i++) {
      const r = await measure(bin, label, i);
      if (r) samples.push(r);
    }
    if (!samples.length) {
      console.error(`${label}: every run timed out`);
      process.exit(1);
    }
    results[label] = {
      startupMsMedian: median(samples.map((s) => s.ms)),
      maxRssKbMedian: median(samples.filter((s) => s.rssKb).map((s) => s.rssKb)) || null,
      samples,
    };
  }

  const startPct = results.candidate.startupMsMedian / results.baseline.startupMsMedian * 100;
  const rssPct = (results.candidate.maxRssKbMedian && results.baseline.maxRssKbMedian)
    ? results.candidate.maxRssKbMedian / results.baseline.maxRssKbMedian * 100
    : null;

  let failures = 0;
  const check = (label, ok, detail) => {
    console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label} — ${detail}`);
    if (!ok) failures++;
  };

  console.log('\nresults');
  check('AC 4.4 cold start < 80% of baseline',
        startPct < 80,
        `${results.baseline.startupMsMedian} ms -> ${results.candidate.startupMsMedian} ms ` +
        `(${startPct.toFixed(1)}%)`);

  if (rssPct === null) {
    console.log('  SKIP  AC 4.5 peak memory — /usr/bin/time produced no Max RSS');
    failures++;
  } else {
    check('AC 4.5 peak memory < 85% of baseline',
          rssPct < 85,
          `${(results.baseline.maxRssKbMedian / 1024).toFixed(1)} MiB -> ` +
          `${(results.candidate.maxRssKbMedian / 1024).toFixed(1)} MiB (${rssPct.toFixed(1)}%)`);
  }

  fs.mkdirSync(path.dirname(JSON_OUT), { recursive: true });
  fs.writeFileSync(JSON_OUT, JSON.stringify({
    generated: new Date().toISOString(),
    runs: RUNS,
    baselineBinary: BASELINE,
    candidateBinary: CANDIDATE,
    results,
    startupPercentOfBaseline: startPct,
    maxRssPercentOfBaseline: rssPct,
  }, null, 2) + '\n');
  console.log(`\nJSON: ${JSON_OUT}`);

  process.exit(failures === 0 ? 0 : 1);
})().catch((e) => { console.error(e); process.exit(2); });
