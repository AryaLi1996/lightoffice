'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');

const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const readJSON = (p) => JSON.parse(read(p));
const exists = (p) => fs.existsSync(path.join(ROOT, p));
const abs = (p) => path.join(ROOT, p);

/**
 * The upstream ONLYOFFICE checkout is not present in CI, so tests that need it
 * are skipped rather than failed — a missing checkout is not a defect in this
 * repository.
 */
function upstream() {
  const p = process.env.LIGHTOFFICE_SRC || path.join(path.dirname(ROOT), 'onlyoffice-src');
  return fs.existsSync(path.join(p, 'web-apps')) ? p : null;
}

/**
 * Read a PNG's dimensions straight out of the IHDR chunk, so the tests do not
 * depend on ImageMagick being installed.
 */
function pngSize(relPath) {
  const buf = fs.readFileSync(abs(relPath));
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (!buf.subarray(0, 8).equals(sig)) throw new Error(`${relPath} is not a PNG`);
  if (buf.subarray(12, 16).toString('ascii') !== 'IHDR') throw new Error(`${relPath} has no IHDR`);
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20), bytes: buf.length };
}

/** Every fenced ```bash block in a markdown file, as arrays of command lines. */
function bashBlocks(relPath) {
  const lines = read(relPath).split('\n');
  const blocks = [];
  let cur = null;
  for (const line of lines) {
    if (cur === null && /^```bash\s*$/.test(line)) { cur = []; continue; }
    if (cur !== null && /^```\s*$/.test(line)) { blocks.push(cur); cur = null; continue; }
    if (cur !== null) cur.push(line);
  }
  return blocks;
}

module.exports = { ROOT, read, readJSON, exists, abs, upstream, pngSize, bashBlocks };
