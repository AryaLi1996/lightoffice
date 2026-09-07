'use strict';

const test = require('node:test');
const assert = require('node:assert');
const yaml = require('js-yaml');
const { read, readJSON, exists } = require('./helpers');

const COMPOSE = 'deploy/docker-compose.nextcloud.yml';
const PROVIDER = 'overlay/desktop-apps/common/loginpage/providers/lightoffice/config.json';
const CLOUD_JS = 'overlay/desktop-apps/common/loginpage/src/lightoffice-cloud.js';

const compose = () => yaml.load(read(COMPOSE));

/**
 * These are the tests that actually earn their keep: the intranet address is
 * written down in four places (compose, the provider config, the client
 * defaults, the deployment guide) and nothing but a test stops them drifting
 * apart. A client pointed at an address the stack no longer listens on fails in
 * a way that looks like a network problem, not a config problem.
 */

test('compose defines the three services on the intranet bridge', () => {
  const c = compose();
  for (const svc of ['db', 'nextcloud', 'documentserver']) {
    assert.ok(c.services[svc], `service ${svc} is missing`);
  }
  assert.strictEqual(c.networks.intranet.ipam.config[0].subnet, '10.0.7.0/24');
});

test('nextcloud holds the static IP the client is configured against', () => {
  const c = compose();
  const ip = c.services.nextcloud.networks.intranet.ipv4_address;
  const port = String(c.services.nextcloud.ports[0]).split(':')[0];

  const provider = readJSON(PROVIDER);
  assert.strictEqual(provider.defaultUrl, `http://${ip}:${port}`,
    'provider defaultUrl does not match the address nextcloud actually listens on');

  const js = read(CLOUD_JS);
  assert.ok(js.includes(`http://${ip}:${port}`),
    `lightoffice-cloud.js does not carry http://${ip}:${port}`);
});

test('document server address is consistent between compose and the client', () => {
  const c = compose();
  const ip = c.services.documentserver.networks.intranet.ipv4_address;
  assert.strictEqual(readJSON(PROVIDER).documentServerUrl, `http://${ip}`);
  assert.ok(read(CLOUD_JS).includes(`http://${ip}`),
    'lightoffice-cloud.js documentServer does not match compose');
});

test('the intranet address is an RFC1918 one, as AC 3.2 requires', () => {
  const url = readJSON(PROVIDER).defaultUrl;
  assert.match(url, /^http:\/\/(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/,
    `${url} is not a private-range address`);
});

test('the deployment guide documents the address the compose file uses', () => {
  const c = compose();
  const ip = c.services.nextcloud.networks.intranet.ipv4_address;
  const port = String(c.services.nextcloud.ports[0]).split(':')[0];
  assert.ok(read('docs/DEPLOYMENT_GUIDE.md').includes(`${ip}:${port}`),
    'DEPLOYMENT_GUIDE.md does not mention the configured intranet address');
});

test('every service pins an explicit image tag', () => {
  const c = compose();
  for (const [name, svc] of Object.entries(c.services)) {
    assert.ok(svc.image, `${name} has no image`);
    assert.ok(svc.image.includes(':'), `${name} image ${svc.image} is untagged`);
    assert.ok(!svc.image.endsWith(':latest') || name === 'documentserver',
      `${name} pins :latest, which makes deployments irreproducible`);
  }
});

test('secrets come from the environment, never hardcoded literals', () => {
  const raw = read(COMPOSE);
  // Every password/secret must be a ${VAR:-default} substitution so a real
  // deployment can override it via deploy/.env.
  for (const key of ['MYSQL_ROOT_PASSWORD', 'MYSQL_PASSWORD',
                     'NEXTCLOUD_ADMIN_PASSWORD', 'JWT_SECRET']) {
    const m = new RegExp(`${key}:\\s*(.+)`).exec(raw);
    assert.ok(m, `${key} not found in compose`);
    assert.match(m[1].trim(), /^\$\{[A-Z_]+(:-[^}]*)?\}$/,
      `${key} is a hardcoded literal (${m[1].trim()})`);
  }
});

test('overlay ships every file apply_overlay.sh installs', () => {
  for (const f of [
    'overlay/web-apps/apps/common/main/resources/themes/theme_lightwps.json',
    'overlay/desktop-apps/win-linux/src/prop/version_p.h',
    'overlay/desktop-apps/common/loginpage/src/lightoffice-cloud.js',
    PROVIDER,
    'overlay/branding/splash.png',
    'overlay/branding/lightoffice.ico',
    'overlay/build/lightoffice_size_opt.pri',
    'overlay/build/lightoffice_size_opt.cmake',
  ]) {
    assert.ok(exists(f), `${f} is referenced by the overlay but not present`);
  }
});

test('the branding header overrides every string it undefines', () => {
  const h = read('overlay/desktop-apps/win-linux/src/prop/version_p.h');
  const undefd = [...h.matchAll(/^#undef\s+(\w+)/gm)].map((m) => m[1]);
  const defined = new Set([...h.matchAll(/^#define\s+(\w+)/gm)].map((m) => m[1]));
  assert.ok(undefd.length > 0, 'no #undef found — the override is not doing anything');
  const missing = undefd.filter((n) => !defined.has(n));
  assert.deepStrictEqual(missing, [],
    `these are #undef'd but never redefined, so the build would fail: ${missing.join(', ')}`);
});
