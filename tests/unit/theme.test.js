'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const { readJSON, upstream } = require('./helpers');

const THEME = 'overlay/web-apps/apps/common/main/resources/themes/theme_lightwps.json';

test('theme is valid JSON with the required top-level fields', () => {
  const t = readJSON(THEME);
  assert.ok(t.name, 'name is missing');
  assert.ok(t.id, 'id is missing');
  assert.equal(t.type, 'light');
  assert.equal(typeof t.colors, 'object');
});

test('theme name is exactly the string AC 2.1 asserts', () => {
  // AC 2.1 checks `jq .name` byte-for-byte, so any re-encoding of this file
  // (mojibake, BOM, escaped sequences) has to fail the suite here rather than
  // in the acceptance run.
  assert.strictEqual(readJSON(THEME).name, '轻量版WPS主题');
});

test('theme covers the full upstream reference key set', () => {
  const colors = readJSON(THEME).colors;
  assert.strictEqual(Object.keys(colors).length, 90,
    'upstream full-theme-light.json.example defines 90 keys; a partial theme ' +
    'silently falls back to defaults for the rest');
});

test('every colour value is a well-formed colour expression', () => {
  const colors = readJSON(THEME).colors;
  const ok = /^(#[0-9a-fA-F]{3,8}|rgba?\(|fade\(|var\()/;
  const bad = Object.entries(colors).filter(([, v]) => !ok.test(v));
  assert.deepStrictEqual(bad, [],
    `malformed colour values: ${bad.map(([k, v]) => `${k}=${v}`).join(', ')}`);
});

test('hex colours have a valid length', () => {
  const colors = readJSON(THEME).colors;
  const bad = Object.entries(colors)
    .filter(([, v]) => v.startsWith('#'))
    .filter(([, v]) => ![4, 5, 7, 9].includes(v.length));
  assert.deepStrictEqual(bad, [], `bad hex length: ${JSON.stringify(bad)}`);
});

test('no duplicate colour keys survived JSON parsing', () => {
  // JSON.parse silently keeps the last of a duplicated key, so compare the
  // parsed key count against the raw occurrences in the file.
  const raw = fs.readFileSync(
    path.join(__dirname, '..', '..', THEME), 'utf8');
  const colorsBlock = raw.slice(raw.indexOf('"colors"'));
  const occurrences = (colorsBlock.match(/^\s{8}"[a-z0-9-]+":/gm) || []).length;
  assert.strictEqual(occurrences, Object.keys(readJSON(THEME).colors).length,
    'a colour key appears more than once');
});

test('theme keys resolve against upstream, no worse than upstream own theme', { skip: !upstream() }, () => {
  const src = upstream();
  const web = path.join(src, 'web-apps', 'apps');

  const vars = new Set();
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (/\.(less|css)$/.test(e.name)) {
        for (const m of fs.readFileSync(p, 'utf8').matchAll(/--([a-z0-9-]+)/g)) vars.add(m[1]);
      }
    }
  };
  walk(web);

  const mine = Object.keys(readJSON(THEME).colors);
  const dangling = mine.filter((k) => !vars.has(k));

  const refPath = path.join(web, 'common/main/resources/themes/full-theme-light.json.example');
  const ref = JSON.parse(fs.readFileSync(refPath, 'utf8'));
  const refDangling = new Set(Object.keys(ref.colors).filter((k) => !vars.has(k)));

  // Keys absent from LESS are fine only where upstream's own reference theme
  // has them too — those are consumed by sdkjs/common/skin.js (the canvas
  // renderer), which never goes through LESS.
  const extra = dangling.filter((k) => !refDangling.has(k));
  assert.deepStrictEqual(extra, [],
    `theme keys that resolve nowhere: ${extra.join(', ')}`);
});
