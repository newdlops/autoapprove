// Local diagnostic consumer for the opt-in source prototype, never migration control.
import assert from 'node:assert/strict';
import {lstat} from 'node:fs/promises';
import {randomBytes} from 'node:crypto';
import {createConnection} from 'node:net';
import path from 'node:path';

const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const socket=option('socket'),pid=Number(option('expected-pid'));
const server=process.argv.includes('--server');
assert.ok(socket&&path.isAbsolute(socket)&&Number.isSafeInteger(pid)&&pid>0,
 'Provide --socket=/private/socket --expected-pid=N from the launched owned process');
const parent=await lstat(path.dirname(socket)),info=await lstat(socket);
assert.ok(parent.isDirectory()&&parent.uid===process.getuid()&&(parent.mode&0o077)===0);
assert.ok(info.isSocket()&&info.uid===process.getuid()&&(info.mode&0o077)===0);
const nonce=randomBytes(16).toString('hex');
const value=await new Promise((resolve,reject)=>{
 const client=createConnection({path:socket});let bytes=Buffer.alloc(0),settled=false;
 const finish=(error,value)=>{if(settled)return;settled=true;client.destroy();error?reject(error):resolve(value);};
 client.setTimeout(3500,()=>finish(Error('Native inventory timed out; no control action sent')));
 client.once('error',error=>finish(error));
 client.once('connect',()=>client.write(JSON.stringify({nonce})+'\n'));
 client.on('data',chunk=>{
  bytes=Buffer.concat([bytes,chunk]);if(bytes.length>1024*1024){finish(Error('Native inventory exceeds limit'));return;}
  const end=bytes.indexOf(10);if(end<0)return;
  try{assert.equal(end,bytes.length-1);finish(null,JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes.subarray(0,end))));}
  catch(error){finish(error);}
 });
 client.once('end',()=>{if(!settled)finish(Error('Native inventory closed without a complete response'));});
});
assert.equal(value.nonce,nonce);assert.equal(value.pid,pid);assert.equal(value.schemaVersion,1);
assert.equal(value.producer,server?'autoapprove-native-server-prototype':'autoapprove-native-tui-prototype');
assert.equal(value.membershipComplete,false);assert.equal(value.admissionGranted,false);
if(server){
 assert.equal(value.error,null);assert.equal(value.consistentRevision,false);
 assert.match(value.serverGeneration,/^[a-f0-9]{8}-[a-f0-9]{4}-7[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i);
 assert.ok(Array.isArray(value.connections)&&value.subscriptions&&Array.isArray(value.subscriptions.initializedConnectionIDs));
 assert.ok(value.subscriptions.byConnection&&value.subscriptions.subscribers);
 for(const row of value.connections){
  assert.ok(Number.isSafeInteger(row.connectionID)&&row.connectionID>=0);
  assert.equal(row.nativePeerIdentified,false);assert.equal(row.clientInventoryBound,false);
 }
 console.log(JSON.stringify(process.argv.includes('--json')?value:{
  verifiedResponse:true,pid:value.pid,serverGeneration:value.serverGeneration,
  transportConnections:value.connections.length,initializedConnections:value.subscriptions.initializedConnectionIDs.length,
  observedThreadEntries:Object.keys(value.subscriptions.subscribers).length,
  consistentRevision:false,membershipComplete:false,admissionGranted:false,limitations:value.limitations
 }));
 process.exit(0);
}
assert.ok(value.stores&&value.currentWidget&&value.retainedInputs);
console.log(JSON.stringify(process.argv.includes('--json')?value:{
 verifiedResponse:true,pid:value.pid,stores:Object.fromEntries(Object.entries(value.stores).map(([k,v])=>[k,v.length])),
 currentWidget:value.currentWidget,membershipComplete:false,admissionGranted:false,limitations:value.limitations
}));
