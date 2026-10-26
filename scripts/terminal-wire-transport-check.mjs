// Actual linked Core owner/gateway, native encoder and gzip. Synthetic source
// adapter only: no terminal input, Bonjour broadcast or physical subnet scan.
import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import vm from 'node:vm';
import path from 'node:path';
import {fixtureSuite,json,wait} from './terminal-continuity-fixture.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const out=path.resolve(option('output')||'.runtime/terminal-wire-transport');
const suite=await fixtureSuite(out,path.resolve(option('build')||'.build/release'));
const window={},context=vm.createContext({window,TextDecoder,TextEncoder,Uint8Array,DataView,BigInt,Number,Map,Set,URL,atob,btoa});
vm.runInContext(await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/terminal-wire.js','utf8'),context);
const checks=[],normal=value=>JSON.parse(JSON.stringify(value));
async function first(node,owner,session,version,extra={},accept=()=>true){
 const query=new URLSearchParams({node:owner.id,session,delta:'1',copy:'1',compact:'1',...(version?{wire:String(version)}:{}),...extra});
 const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),10000);
 const response=await fetch(node.url+'/api/terminal/stream?'+query,{headers:{'Accept-Encoding':'gzip'},signal:controller.signal});
 assert.equal(response.status,200);assert.equal(response.headers.get('x-autoapprove-node'),node.id);assert.equal(response.headers.get('content-encoding'),'gzip');
 assert.ok(response.headers.get('content-type').startsWith(version?'application/vnd.autoapprove.terminal-v'+version:'text/event-stream'));
 const reader=response.body.getReader(),events=[],parser=version?new window.AutoApproveTerminalWire.Parser(false,version):new window.AutoApproveTerminalWire.SSEParser();let firstBytes;
 try{
  let selected;
  while(!selected){
   const {value,done}=await reader.read();assert.equal(done,false);firstBytes??=Buffer.from(value);parser.push(value,event=>events.push(event));
   for(const event of events.splice(0))if(event.type==='screen'){const decoded=version?normal(event.value):JSON.parse(event.data);if(accept(decoded)){selected=decoded;break;}}
  }
  if(version){assert.equal(firstBytes[2],version);assert.equal(firstBytes[3],0,'Normal native DTOs must use typed encoding');}return selected;
 }finally{clearTimeout(timeout);controller.abort();await reader.cancel().catch(()=>{});reader.releaseLock();}
}
try{
 const owner=await suite.start('owner'),gateway=await suite.start('gateway');
 const added=await json(gateway.url+'/api/peers',{address:owner.url});assert.equal(added.status,200);assert.equal(added.value.id,owner.id);
 const state=(await json(owner.url+'/api/state')).value;assert.equal(state.terminalWireVersion,3);const session=state.sessions[0].session.id;
 const reference=(await json(owner.url+'/api/terminal?'+new URLSearchParams({session}))).value;
 let basis;
 for(const node of [owner,gateway])for(const version of [0,2,3]){
  const value=await first(node,owner,session,version);
  for(const key of ['sessionID','screen','streamID','cursor','appearance','keys'])assert.deepEqual(value[key],reference[key],key);
  checks.push({route:node===owner?'owner':'gateway',version:version||'SSE',screenUnits:value.screen.length,exactCursorAndAppearance:true});
  if(node===gateway&&version===3)basis=value;
 }
 await suite.control(owner,{append:'\nWIRE3-NATIVE-APPEND-한글🧪'});await wait(850);
 const update=await first(gateway,owner,session,3,{revision:basis.revision,stream:basis.streamID},value=>!!value.screenPatch);
 assert.ok(update.screenPatch,'Native resume must exercise the compact patch schema: '+JSON.stringify({base:basis.revision,next:update.revision,keys:Object.keys(update),screenLength:update.screen?.length}));const patch=update.screenPatch;
 assert.equal(patch.baseRevision,basis.revision);assert.equal(patch.baseLength,basis.screen.length);
 const restored=basis.screen.slice(0,patch.prefix)+patch.text+basis.screen.slice(basis.screen.length-patch.suffix);
 assert.equal(restored,basis.screen+'\nWIRE3-NATIVE-APPEND-한글🧪');assert.equal(restored.length,patch.length);
 assert.equal((await suite.observe(owner)).inputs.length,0);checks.push({route:'gateway',version:3,exactNativePatch:true,inputPosts:0});
 const report={passed:true,checks,actualLinkedCoreOwnerAndGateway:true,encoderSourceRecompiled:false,gzip:true,scope:'Synthetic loopback sources; no physical phone or user CLI'};
 await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}finally{await suite.stop();}
