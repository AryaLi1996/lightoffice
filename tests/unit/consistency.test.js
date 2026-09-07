'use strict';

const test = require('node:test');
const assert = require('node:assert');
const yaml = require('js-yaml');
const { read, readJSON, exists } = require('./helpers');

const COMPOSE = 'deploy/docker-compose.nextcloud.yml';
const CFN = 'deploy/aws/lightoffice-stack.yaml';
const PROVIDER = 'overlay/desktop-apps/common/loginpage/providers/lightoffice/config.json';
const CLOUD_JS = 'overlay/desktop-apps/common/loginpage/src/lightoffice-cloud.js';

const compose = () => yaml.load(read(COMPOSE));

/**
 * CloudFormation templates use short-form intrinsics (!Ref, !Sub, !GetAtt)
 * that plain YAML cannot represent. We only need the literal values here, so
 * unknown tags resolve to a marker rather than failing the parse.
 */
function loadCfn() {
  const schema = yaml.DEFAULT_SCHEMA.extend(
    ['scalar', 'sequence', 'mapping'].map((kind) => new yaml.Type('!', {
      kind,
      multi: true,
      construct: (data) => ({ __cfnIntrinsic: data }),
    })),
  );
  return yaml.load(read(CFN), { schema });
}

/** The one address clients use, taken from where it is authoritative. */
function publicHost() {
  return new URL(readJSON(PROVIDER).defaultUrl).hostname;
}

/**
 * These tests exist because the client-facing address is written down in five
 * places — the CloudFormation stack, the compose defaults, the provider
 * config, the client defaults and the deployment guide — and the client
 * compiles it in at build time. Drift between any two of them produces a
 * client that cannot reach the server, failing in a way that looks like a
 * network fault rather than a configuration one.
 */

// ---------------------------------------------------------------- topology --
test('compose defines the three services on an internal bridge', () => {
  const c = compose();
  for (const svc of ['db', 'nextcloud', 'documentserver']) {
    assert.ok(c.services[svc], `service ${svc} is missing`);
  }
  assert.ok(c.networks.intranet.ipam.config[0].subnet, 'bridge has no subnet');
});

test('the container bridge does not overlap the host subnet', () => {
  // On the AWS host, 10.0.7.0/24 belongs to the VPC subnet. A docker bridge
  // on the same range would give the host two routes for it and blackhole its
  // own traffic — including the address clients connect to.
  const bridge = compose().networks.intranet.ipam.config[0].subnet;
  const cfn = loadCfn();
  const hostSubnet = cfn.Parameters.PrivateSubnetCidr.Default;

  const net = (cidr) => {
    const [ip, bits] = cidr.split('/');
    const n = ip.split('.').reduce((a, o) => (a << 8) + Number(o), 0) >>> 0;
    const mask = bits === '0' ? 0 : (0xffffffff << (32 - Number(bits))) >>> 0;
    return { base: (n & mask) >>> 0, mask };
  };
  const a = net(bridge);
  const b = net(hostSubnet);
  const shared = (a.mask & b.mask) >>> 0;
  assert.notStrictEqual((a.base & shared) >>> 0, (b.base & shared) >>> 0,
    `docker bridge ${bridge} overlaps the host subnet ${hostSubnet}`);
});

// ------------------------------------------------------- client addressing --
test('client portal and document server point at the same published host', () => {
  const c = compose();
  const host = publicHost();
  const portalPort = String(c.services.nextcloud.ports[0]).split(':')[0];
  const dsPort = String(c.services.documentserver.ports[0]).split(':')[0];

  assert.strictEqual(readJSON(PROVIDER).defaultUrl, `http://${host}:${portalPort}`);
  assert.strictEqual(readJSON(PROVIDER).documentServerUrl, `http://${host}:${dsPort}`);

  const js = read(CLOUD_JS);
  assert.ok(js.includes(`defaultPortal: 'http://${host}:${portalPort}'`),
    `lightoffice-cloud.js defaultPortal does not match http://${host}:${portalPort}`);
  assert.ok(js.includes(`documentServer: 'http://${host}:${dsPort}'`),
    `lightoffice-cloud.js documentServer does not match http://${host}:${dsPort}`);
});

test('clients are never pointed at a container bridge address', () => {
  // A bridge IP resolves only inside the host; a client configured with one
  // simply times out. This is the specific mistake the test guards.
  const c = compose();
  const bridgeIps = Object.values(c.services)
    .map((s) => s.networks && s.networks.intranet && s.networks.intranet.ipv4_address)
    .filter(Boolean);
  const clientFacing = [
    readJSON(PROVIDER).defaultUrl,
    readJSON(PROVIDER).documentServerUrl,
    read(CLOUD_JS),
  ].join(' ');
  for (const ip of bridgeIps) {
    assert.ok(!clientFacing.includes(ip),
      `${ip} is a container bridge address but appears in client-facing config`);
  }
});

test('the address is RFC1918, as AC 3.2 requires', () => {
  assert.match(publicHost(), /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/,
    `${publicHost()} is not a private-range address`);
});

// ------------------------------------------------------------ CloudFormation --
test('CloudFormation pins the host to the address clients compile in', { skip: !exists(CFN) }, () => {
  const cfn = loadCfn();
  assert.strictEqual(cfn.Parameters.HostPrivateIp.Default, publicHost(),
    'HostPrivateIp does not match the address baked into the client');
  assert.strictEqual(
    cfn.Resources.Host.Properties.PrivateIpAddress.__cfnIntrinsic, 'HostPrivateIp',
    'the instance does not pin a fixed private IP, so the address can change under the clients');
});

test('CloudFormation opens exactly the ports the client needs', () => {
  const c = compose();
  const wanted = [c.services.nextcloud, c.services.documentserver]
    .map((s) => Number(String(s.ports[0]).split(':')[0]))
    .sort((a, b) => a - b);
  const opened = loadCfn().Resources.HostSecurityGroup.Properties.SecurityGroupIngress
    .map((r) => r.FromPort).sort((a, b) => a - b);
  assert.deepStrictEqual(opened, wanted,
    'security group ingress does not match the published container ports');
});

test('CloudFormation keeps the host off the public internet', () => {
  const cfn = loadCfn();
  const host = cfn.Resources.Host.Properties;
  assert.ok(!host.PublicIp && host.SubnetId.__cfnIntrinsic === 'PrivateSubnet',
    'the host must sit in the private subnet');
  assert.strictEqual(cfn.Resources.PrivateSubnet.Properties.MapPublicIpOnLaunch, false);
  assert.strictEqual(host.MetadataOptions.HttpTokens, 'required', 'IMDSv2 should be enforced');

  // Ingress must come from a parameter constrained to RFC1918, never 0.0.0.0/0.
  for (const rule of cfn.Resources.HostSecurityGroup.Properties.SecurityGroupIngress) {
    assert.strictEqual(rule.CidrIp.__cfnIntrinsic, 'CorporateCidr',
      'ingress should be restricted to the corporate range');
  }
  assert.match(cfn.Parameters.CorporateCidr.AllowedPattern, /^\^\(10\|172\|192\)/,
    'CorporateCidr should be constrained to private ranges');
});

test('CloudFormation encrypts persistent storage and keeps it on replace', () => {
  const cfn = loadCfn();
  assert.strictEqual(cfn.Resources.DataVolume.Properties.Encrypted, true);
  assert.strictEqual(cfn.Resources.DataVolume.DeletionPolicy, 'Snapshot',
    'deleting the stack should not silently destroy company documents');
  assert.strictEqual(
    cfn.Resources.Host.Properties.BlockDeviceMappings[0].Ebs.Encrypted, true);
});

// ------------------------------------------------------------------- misc ---
test('the deployment guide documents the configured address', () => {
  const c = compose();
  const port = String(c.services.nextcloud.ports[0]).split(':')[0];
  assert.ok(read('docs/DEPLOYMENT_GUIDE.md').includes(`${publicHost()}:${port}`),
    'DEPLOYMENT_GUIDE.md does not mention the configured address');
});

test('every service pins an explicit image tag', () => {
  for (const [name, svc] of Object.entries(compose().services)) {
    assert.ok(svc.image, `${name} has no image`);
    assert.ok(svc.image.includes(':'), `${name} image ${svc.image} is untagged`);
    assert.ok(!svc.image.endsWith(':latest') || name === 'documentserver',
      `${name} pins :latest, which makes deployments irreproducible`);
  }
});

test('secrets come from the environment, never hardcoded literals', () => {
  const raw = read(COMPOSE);
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
    CLOUD_JS,
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
