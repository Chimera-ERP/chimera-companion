import {test} from 'node:test';
import assert from 'node:assert/strict';
import {version,validateApk,releaseManifest,signingCertificate} from './release.mjs';
const v=version('version: 0.1.44+46\n');
const badge="package: name='ro.chimeraerp.companion' versionCode='46' versionName='0.1.44'";
const certificate=`Signer #1 certificate SHA-256 digest: ${signingCertificate}`;
test('accepts the canonical package and certificate, rejects legacy package',()=>{
  assert.doesNotThrow(()=>validateApk(v,badge,certificate));
  for(const bad of [badge.replace("'46'","'45'"),badge.replace('ro.chimeraerp.companion','ro.tabusociety.chimera_companion'),badge+'\napplication-debuggable'])
    assert.throws(()=>validateApk(v,bad,certificate));
  assert.throws(()=>validateApk(v,badge,certificate.replace(signingCertificate,'a'.repeat(64))));
});
test('rejects non-stable or missing Android version codes',()=>{
  for(const value of ['version: 1.2.3','version: 1.2.3+0','version: 1.2.3-beta+46'])assert.throws(()=>version(value));
});
test('manifest identifies the exact source and immutable artifact',()=>{
  const m=releaseManifest(v,Buffer.from('test'),'a'.repeat(40));
  assert.equal(m.versionCode,46);assert.equal(m.size,4);
  assert.match(m.url,/releases\/download\/v0\.1\.44\/companion-0\.1\.44\.apk$/);
  assert.equal(m.signingCertificateSha256,signingCertificate);
  assert.throws(()=>releaseManifest(v,Buffer.from('test'),'main'));
});
