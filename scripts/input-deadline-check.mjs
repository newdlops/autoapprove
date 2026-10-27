// Deterministic silent-transport faults; production browser source, no sockets
// or user input. Advances timer time rather than sleeping through deadlines.
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const source=await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/input-channel.js','utf8');
const checks=[];
function fixture({mode='pty',pong=false}={}){
 let now=0,next=0,Channel;const timers=new Map(),sockets=[],writes=[],failures=[];
 const timeout=(fn,delay,repeat=0)=>{const id=++next;timers.set(id,{fn,due:now+delay,repeat});return id;};
 const flush=async()=>{for(let i=0;i<8;i++)await Promise.resolve();};
 async function advance(ms){const until=now+ms;for(let n=0;n<10000;n++){const task=[...timers].filter(([,value])=>value.due<=until).sort((a,b)=>a[1].due-b[1].due)[0];if(!task)break;const[id,value]=task;now=value.due;if(value.repeat)value.due+=value.repeat;else timers.delete(id);value.fn();await flush();}now=until;await flush();}
 class Socket{
  static OPEN=1;
  constructor(){this.readyState=1;this.bufferedAmount=0;sockets.push(this);queueMicrotask(()=>this.onopen?.());}
  emit(kind,sequence=0,payload=new Uint8Array()){this.onmessage?.({data:Channel.packet(kind,sequence,payload).buffer});}
  send(bytes){const kind=bytes[3],sequence=new DataView(bytes.buffer).getUint32(4);if(kind===0)queueMicrotask(()=>this.emit(1));else if(kind===6){if(pong)queueMicrotask(()=>this.emit(7,0,bytes.slice(8)));}else writes.push({kind,sequence});}
  close(){this.readyState=3;}
 }
 const context={window:{},location:new URL('https://deadline.invalid/'),WebSocket:Socket,URL,TextEncoder,TextDecoder,Uint8Array,ArrayBuffer,DataView,performance:{now:()=>now},queueMicrotask,
  setTimeout:(fn,ms)=>timeout(fn,ms),clearTimeout:id=>timers.delete(id),setInterval:(fn,ms)=>timeout(fn,ms,ms),clearInterval:id=>timers.delete(id)};
 vm.runInNewContext(source,context);Channel=context.window.AutoApproveInputChannel;
 const channel=new Channel('synthetic',{mode},{onFailure:error=>failures.push(error)});
 return {channel,advance,sockets,writes,failures,timers};
}
for(const mode of ['pty','native','screen']){
 const deadline=mode==='screen'?3000:7500,idle=fixture({mode});await idle.channel.open();await idle.advance(deadline-1);assert.equal(idle.channel.state,'ready');
 await idle.advance(2);assert.equal(idle.channel.state,'closed');assert.equal(idle.failures.length,1);assert.equal(idle.failures[0].recoverable,true);assert.equal(idle.writes.length,0);assert.equal(idle.sockets.length,1);assert.equal(idle.timers.size,0);
 const uncertain=fixture({mode});await uncertain.channel.open();assert.equal(uncertain.channel.send(mode==='screen'?8:mode==='native'?3:2,new Uint8Array([6])),true);
 await uncertain.advance(deadline+1);assert.equal(uncertain.channel.state,'closed');assert.equal(uncertain.failures.length,1);assert.equal(uncertain.failures[0].recoverable,false);assert.equal(uncertain.channel.pendingCount,1);
 await uncertain.advance(60000);assert.equal(uncertain.writes.length,1);assert.equal(uncertain.sockets.length,1);assert.equal(uncertain.timers.size,0);
 const healthy=fixture({mode,pong:true});await healthy.channel.open();await healthy.advance(120000);assert.equal(healthy.channel.state,'ready');assert.equal(healthy.failures.length,0);assert.equal(healthy.timers.size,1);
 healthy.channel.close();assert.equal(healthy.timers.size,0);
 checks.push(mode+': silent idle is recoverable; pending input stays uncertain without replay; healthy pong and close leave no deadline timers');
}
console.log(JSON.stringify({passed:true,checks,scope:'Production JavaScript with deterministic WebSocket/timer fault injection; real browsers and native paths are checked separately'}));
