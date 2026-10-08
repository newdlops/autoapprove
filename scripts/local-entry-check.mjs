// Verify entry latency independently of browser startup, with isolated Macs.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {coreLinkArguments} from './swift-core-link.mjs';

const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const binary=path.resolve('.build/qa/LocalEntryPreview');
await mkdir(path.dirname(binary),{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/LocalEntryPreview'),'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(n=>n.endsWith('.swift.o')).map(n=>path.join(build,'AutoApproveCore.build',n)),'Tests/fixtures/network-preview.swift','-o',binary],{stdio:'inherit'});
const root=await mkdtemp(path.join(tmpdir(),'autoapprove-local-entry-'));
const children=[];
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function start(label,version) {
  const child=spawn(binary,[path.join(root,label),label,'--direct-only','--web-version='+version],{stdio:['ignore','pipe','pipe']});
  children.push(child);
  return await new Promise((resolve,reject)=>{
    let stdout='',stderr='';
    const timer=setTimeout(()=>reject(new Error('Fixture startup: '+stderr)),20000);
    child.stderr.on('data',data=>stderr+=data);
    child.stdout.on('data',data=>{
      stdout+=data;
      for(const line of stdout.split('\n')) {
        try {const value=JSON.parse(line);if(value.url){clearTimeout(timer);resolve({...value,child});return;}}catch{}
      }
    });
    child.once('exit',code=>{clearTimeout(timer);reject(new Error('Fixture exit '+code+': '+stderr));});
  });
}
try {
  const [local,newer]=await Promise.all([start('A','0.2.9:20'),start('B','0.2.10:12')]);
  await writeFile(path.join(root,'direct-peers.json'),JSON.stringify([local.url,newer.url]));
  let verified=false;
  for(let attempt=0;attempt<50;attempt++) {
    const state=await (await fetch(local.url+'/api/network',{signal:AbortSignal.timeout(3000)})).json();
    if(state.preferredGateway?.id===newer.id){verified=true;break;}
    await wait(200);
  }
  assert.ok(verified,'The newer Mac must be discovered and verified before it stalls');
  newer.child.kill('SIGSTOP');
  const times=[];
  try {
    for(const route of ['/','/index.html','/?webNode='+local.id,'/']) {
      const started=performance.now();
      const response=await fetch(local.url+route,{redirect:'manual',signal:AbortSignal.timeout(1000)});
      assert.equal(response.status,200);
      assert.equal(response.headers.get('cache-control'),'no-store');
      assert.match(await response.text(),/0\.2\.9:20:1/);
      const elapsed=performance.now()-started;
      assert.ok(elapsed<350,'Entry waited '+elapsed.toFixed(1)+'ms for an unresponsive newer Mac');
      times.push(Math.round(elapsed));
    }
    assert.equal((await fetch(local.url+'/?webNode='+newer.id,{redirect:'manual',signal:AbortSignal.timeout(1000)})).status,409);
  } finally {newer.child.kill('SIGCONT');}
  console.log(JSON.stringify({passed:true,firstHTMLms:times,limitMs:350,localDocument:true,noRedirect:true,wrongNodeRejected:true},null,2));
} finally {
  children.forEach(child=>{child.kill('SIGCONT');child.kill();});
  await rm(root,{recursive:true,force:true});
}
