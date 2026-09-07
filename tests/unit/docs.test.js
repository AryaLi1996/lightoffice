'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const { read, readJSON, exists, upstream, pngSize, bashBlocks } = require('./helpers');

test('all three guides are present', () => {
  for (const f of ['docs/USER_GUIDE.md', 'docs/DEPLOYMENT_GUIDE.md', 'docs/DEVELOPER_GUIDE.md']) {
    assert.ok(exists(f), `${f} is missing`);
  }
});

test('deployment guide carries at least 10 runnable commands (AC 5.4)', () => {
  const cmds = bashBlocks('docs/DEPLOYMENT_GUIDE.md')
    .flat()
    .filter((l) => l.trim() && !l.trim().startsWith('#'));
  assert.ok(cmds.length >= 10, `only ${cmds.length} command lines found`);
});

test('deployment guide has no unresolved placeholders (AC 5.4)', () => {
  // {{UPPER_SNAKE}} is the placeholder form; Go templates such as
  // {{.State.Health.Status}} inside docker inspect commands are legitimate.
  const left = read('docs/DEPLOYMENT_GUIDE.md').match(/\{\{[A-Z][A-Z0-9_]*\}\}/g) || [];
  assert.deepStrictEqual(left, [], `unreplaced placeholders: ${left.join(', ')}`);
});

test('developer guide contains a mermaid diagram', () => {
  assert.match(read('docs/DEVELOPER_GUIDE.md'), /^```mermaid$/m);
});

test('mermaid node identifiers name real classes (AC 5.5)', { skip: !upstream() }, () => {
  const src = upstream();
  const doc = read('docs/DEVELOPER_GUIDE.md');
  const block = doc.slice(doc.indexOf('```mermaid'));
  const diagram = block.slice(0, block.indexOf('\n```', 3));

  const ids = [...new Set([...diagram.matchAll(/^\s*(C[A-Za-z_]+)\[/gm)].map((m) => m[1]))];
  assert.ok(ids.length > 0, 'no C-prefixed node identifiers found in the diagram');

  const dir = path.join(src, 'desktop-apps', 'win-linux', 'src');
  const headers = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.h')) headers.push(fs.readFileSync(p, 'utf8'));
    }
  };
  walk(dir);
  const blob = headers.join('\n');

  const missing = ids.filter((id) => !new RegExp(`class\\s+${id}\\b`).test(blob));
  assert.deepStrictEqual(missing, [],
    `diagram names classes that do not exist in desktop-apps/src: ${missing.join(', ')}`);
});

test('splash screen is 600x300 and not a placeholder (AC 2.3)', () => {
  const { width, height, bytes } = pngSize('overlay/branding/splash.png');
  assert.strictEqual(width, 600);
  assert.strictEqual(height, 300);
  // A flat placeholder of this size compresses to a few hundred bytes.
  assert.ok(bytes > 4000, `splash.png is only ${bytes} bytes, likely a placeholder`);
});

test('every generated icon size is square and correctly sized', () => {
  for (const s of [16, 24, 32, 48, 64, 128, 256]) {
    const { width, height } = pngSize(`overlay/branding/lightoffice_${s}.png`);
    assert.strictEqual(width, s, `lightoffice_${s}.png width`);
    assert.strictEqual(height, s, `lightoffice_${s}.png height`);
  }
});

test('code_index has the three keys AC 1.5 requires', () => {
  const idx = readJSON('code_index.json');
  for (const k of ['theme_path', 'menu_config_path', 'cloud_provider_registry']) {
    assert.ok(idx.index[k], `code_index.json is missing ${k}`);
    assert.ok(idx.index[k].path, `${k} has no path`);
  }
});

test('every code_index entry is described and well-formed', () => {
  const idx = readJSON('code_index.json');
  assert.strictEqual(idx.schema, 'lightoffice/code-index@1');
  for (const [k, v] of Object.entries(idx.index)) {
    assert.ok(v.description, `${k} has no description`);
    assert.ok(v.path || v.paths, `${k} has neither path nor paths`);
    if (v.path) assert.ok(!v.path.startsWith('/'), `${k} path should be repo-relative`);
  }
});

test('code_index paths exist in the upstream checkout', { skip: !upstream() }, () => {
  const src = upstream();
  const idx = readJSON('code_index.json');
  const missing = [];
  for (const [k, v] of Object.entries(idx.index)) {
    const paths = v.path ? [v.path] : v.paths.map((p) => p.path);
    for (const p of paths) if (!fs.existsSync(path.join(src, p))) missing.push(`${k} -> ${p}`);
  }
  assert.deepStrictEqual(missing, [], `stale index entries: ${missing.join(', ')}`);
});
