#!/usr/bin/env node
'use strict';

// Administrative provisioning tool. Cloudflare credentials stay on this host;
// only the unique leaf key/certificate are copied into Companion private storage.
const fs = require('node:fs/promises');
const path = require('node:path');
const dns = require('node:dns').promises;
const net = require('node:net');

async function main() {
  const [hostname, address, output, cloudflareLogin, acmeModule] = process.argv.slice(2);
  if (!hostname || !/^[a-z0-9.-]+$/.test(hostname) || net.isIP(address) !== 4 || !output || !cloudflareLogin || !acmeModule) {
    throw new Error('Usage: node provision_public_tls.cjs hostname LAN-IP private-output cloudflared-login.pem acme-client-module');
  }
  const acme = require(path.resolve(acmeModule));
  const pem = await fs.readFile(cloudflareLogin, 'utf8');
  const match = pem.match(/-----BEGIN ARGO TUNNEL TOKEN-----([\s\S]*?)-----END ARGO TUNNEL TOKEN-----/);
  if (!match) throw new Error('Cloudflare login token not found');
  const credentials = JSON.parse(Buffer.from(match[1].replace(/\s/g, ''), 'base64').toString());
  async function cf(endpoint, method = 'GET', body) {
    const response = await fetch(`https://api.cloudflare.com/client/v4/zones/${credentials.zoneID}${endpoint}`, {
      method,
      headers: {Authorization: `Bearer ${credentials.apiToken}`, 'Content-Type': 'application/json'},
      ...(body ? {body: JSON.stringify(body)} : {}),
      signal: AbortSignal.timeout(15000),
    });
    const result = await response.json();
    if (!response.ok || !result.success) throw new Error(`Cloudflare ${response.status}: ${(result.errors || []).map(e => e.code).join(',')}`);
    return result.result;
  }
  const zone = await cf('');
  if (!hostname.endsWith(`.${zone.name}`)) throw new Error('Hostname is outside the authorized zone');
  const records = await cf(`/dns_records?name=${encodeURIComponent(hostname)}`);
  if (records.length && !records.every(r => r.type === 'A' && r.content === address && !r.proxied)) {
    throw new Error('Hostname already has different DNS records; refusing to overwrite');
  }
  await fs.mkdir(output, {recursive: true, mode: 0o700});
  const keyFile = path.join(output, 'acme-account-key.pem');
  let accountKey;
  try { accountKey = await fs.readFile(keyFile); }
  catch (error) {
    if (error.code !== 'ENOENT') throw error;
    accountKey = await acme.crypto.createPrivateKey();
    await fs.writeFile(keyFile, accountKey, {mode: 0o600, flag: 'wx'});
  }
  const [privateKey, csr] = await acme.crypto.createCsr({commonName: hostname, altNames: [hostname]});
  const client = new acme.Client({directoryUrl: acme.directory.letsencrypt.production, accountKey});
  const created = new Map();
  const resolver = new dns.Resolver();
  resolver.setServers(['1.1.1.1', '8.8.8.8']);
  const certificate = await client.auto({
    csr, termsOfServiceAgreed: true, challengePriority: ['dns-01'],
    challengeCreateFn: async (authorization, challenge, value) => {
      if (challenge.type !== 'dns-01') throw new Error('DNS validation required');
      const name = `_acme-challenge.${authorization.identifier.value}`;
      const record = await cf('/dns_records', 'POST', {type: 'TXT', name, content: value, ttl: 60});
      created.set(name, record.id);
      console.log('DNS challenge created; waiting for propagation.');
      for (let attempt = 0; attempt < 30; attempt++) {
        try {
          const values = await resolver.resolveTxt(name);
          if (values.some(v => v.join('') === value)) return;
        } catch {}
        await new Promise(resolve => setTimeout(resolve, 2000));
      }
      throw new Error('DNS challenge did not propagate');
    },
    challengeRemoveFn: async (authorization) => {
      const name = `_acme-challenge.${authorization.identifier.value}`;
      const id = created.get(name);
      if (id) { await cf(`/dns_records/${id}`, 'DELETE'); created.delete(name); }
    },
  });
  await fs.writeFile(path.join(output, 'private-key.pem'), privateKey, {mode: 0o600});
  await fs.writeFile(path.join(output, 'certificate.pem'), certificate, {mode: 0o600});
  await fs.writeFile(path.join(output, 'endpoint.json'), JSON.stringify({origin: `https://${hostname}:8765`}), {mode: 0o600});
  if (!records.length) await cf('/dns_records', 'POST', {type: 'A', name: hostname, content: address, proxied: false, ttl: 3600});
  console.log(`Public certificate provisioned: https://${hostname}:8765`);
  console.log('Configure LAN DNS for this hostname before qualifying offline operation.');
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
