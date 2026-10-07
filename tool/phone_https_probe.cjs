#!/usr/bin/env node
'use strict';

// Uses the phone's actual Chrome certificate store. No TLS override is installed.
async function main() {
  const [targetId, endpoint, mode] = process.argv.slice(2);
  if (!targetId || new URL(endpoint).protocol !== 'https:') throw new Error('Usage: node phone_https_probe.cjs POS-tab-id https://companion-host:8765');
  const tabs = await (await fetch('http://127.0.0.1:9223/json/list')).json();
  const target = tabs.find(t => t.id === targetId && t.type === 'page');
  if (!target) throw new Error('POS tab not available');
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let sequence = 0;
  const pending = new Map();
  socket.onmessage = event => {
    const reply = JSON.parse(event.data);
    if (reply.id && pending.has(reply.id)) {
      const {resolve, reject, timer} = pending.get(reply.id);
      pending.delete(reply.id); clearTimeout(timer);
      if (reply.error) reject(new Error(reply.error.message)); else resolve(reply.result);
    }
  };
  function call(method, params) {
    return new Promise((resolve, reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error('Phone probe timed out')); }, 20000);
      pending.set(id, {resolve, reject, timer});
      socket.send(JSON.stringify({id, method, params}));
    });
  }
  try {
    await call('Page.bringToFront', {});
    const expression = mode?.startsWith('--enroll-pos=')
      ? `(async()=>{try{const api=await import('/lib/api.ts');const {saveConfig}=await import('/lib/config.ts');const enrollment=await api.enrollDeviceWithPin({authUrl:'https://devchimera.tabusociety.ro',pin:${JSON.stringify(mode?.slice('--enroll-pos='.length))},deviceName:'POS Copou phone test'});if(!saveConfig('https://devchimera.tabusociety.ro',enrollment.token,'https://devchimera.tabusociety.ro'))throw Error('Invalid enrollment');return {status:200,secureContext:isSecureContext,deviceId:enrollment.device_id,locationId:enrollment.location_id}}catch(error){return {error:error.message}}})()`
      : mode === '--inspect-pos'
      ? `(async()=>{try{const {loadConfig}=await import('/lib/config.ts');const api=await import('/lib/api.ts');const config=loadConfig();if(!config)throw Error('POS not enrolled');const [catalog,roster]=await Promise.all([api.syncPull(config),api.fetchPosOperators(config)]);return {status:200,secureContext:isSecureContext,catalogKeys:Object.keys(catalog),productCount:catalog.products?.length,operatorCount:roster.operators?.length}}catch(error){return {error:error.message}}})()`
      : mode === '--reload-pos'
      ? `(async()=>{location.reload();return {status:200,secureContext:isSecureContext}})()`
      : mode === '--signed-status'
      ? `(async()=>{try{const {loadConfig}=await import('/lib/config.ts');const bridge=await import('/lib/companion.ts');const config=loadConfig();if(!config)throw Error('POS not enrolled');let companion=await bridge.loadCompanion(config);if(!companion){const peers=await bridge.listCompanions(config);if(peers.length!==1)throw Error('Select one Companion in POS settings first');companion={companionId:peers[0].id}}await bridge.saveCompanion(config,${JSON.stringify(endpoint)},companion.companionId);companion=await bridge.loadCompanion(config);const result=await bridge.companionCommand(config,companion,'status',crypto.randomUUID(),{});return {origin:location.origin,secureContext:isSecureContext,status:200,outcome:result.outcome,message:result.message}}catch(error){return {origin:location.origin,secureContext:isSecureContext,error:error.message}}})()`
      : `(async()=>{try{const response=await fetch(${JSON.stringify(endpoint + '/health')},{cache:'no-store',signal:AbortSignal.timeout(12000)});return {origin:location.origin,secureContext:isSecureContext,status:response.status,body:await response.json()}}catch(error){return {origin:location.origin,secureContext:isSecureContext,error:error.message}}})()`;
    const result = await call('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true});
    const value = result.result?.value;
    console.log(JSON.stringify(value || {error: 'Probe did not return a result'}));
    if (value?.status !== 200 || !value?.secureContext) process.exitCode = 1;
  } finally { socket.close(); }
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
