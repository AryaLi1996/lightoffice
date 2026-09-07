#!/usr/bin/env node
/*
 * Test fixture host for the co-editing check.
 *
 * The Document Server has to be able to (a) download the document being edited
 * and (b) POST status callbacks back. A plain static file server satisfies only
 * the first, and the editors then raise warning -101 ("document could not be
 * saved"), which muddies the result — so this serves the fixtures over GET and
 * accepts the callback over POST.
 *
 * Binds on the host side of the compose bridge, so containers reach it at
 * 10.0.7.1:<port>.
 *
 *   node tests/fixture_server.js [--port 8099] [--dir /tmp/served]
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const PORT = parseInt(arg('--port', '8099'), 10);
const DIR = path.resolve(arg('--dir', '/tmp/served'));
const CALLBACKS = [];

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.json': 'application/json',
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  // Document Server status callback. Answering {"error":0} is what stops the
  // editors from reporting warning -101.
  if (req.method === 'POST' && url.pathname === '/callback') {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      let parsed = null;
      try { parsed = JSON.parse(body); } catch (_) { /* keep raw */ }
      CALLBACKS.push({ at: new Date().toISOString(), status: parsed && parsed.status, body: body.slice(0, 400) });
      console.log(`callback status=${parsed ? parsed.status : '?'} users=${parsed && parsed.users ? parsed.users.join(',') : '-'}`);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end('{"error":0}');
    });
    return;
  }

  if (url.pathname === '/callbacks.json') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(CALLBACKS, null, 2));
    return;
  }

  const file = path.join(DIR, path.normalize(url.pathname).replace(/^(\.\.[/\\])+/, ''));
  if (!file.startsWith(DIR) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404); res.end('not found'); return;
  }
  res.writeHead(200, {
    'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream',
    'Access-Control-Allow-Origin': '*',
  });
  fs.createReadStream(file).pipe(res);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`fixture server on 0.0.0.0:${PORT} serving ${DIR}`);
  console.log(`containers reach it at http://10.0.7.1:${PORT}/`);
});
