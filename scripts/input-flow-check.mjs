// Production browser writers with deterministic clock, credit and socket faults.
// No actual socket, user terminal, desktop capture or native event is used.
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const baseline=process.argv.includes('--baseline');
const channelSource=await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/input-channel.js','utf8');
const screenSource=await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/screen-control.js','utf8');
function clock(){
 let now=0,next=0,created=0;const timers=new Map();
 const timeout=(fn,delay,repeat=0)=>{if(!repeat)created++;const id=++next;timers.set(id,{fn,due:now+delay,repeat});return id;};
 const flush=async()=>{for(let n=0;n<12;n++)await Promise.resolve();};
 async function advance(ms){const end=now+ms;for(let n=0;n<10000;n++){const task=[...timers].filter(([,value])=>value.due<=end).sort((a,b)=>a[1].due-b[1].due)[0];if(!task)break;const[id,value]=task;now=value.due;if(value.repeat)value.due+=value.repeat;else timers.delete(id);value.fn();await flush();}now=end;await flush();}
 return {get now(){return now;},get created(){return created;},reset(){created=0;},timers,advance,flush,api:{performance:{now:()=>now},setTimeout:(fn,ms)=>timeout(fn,ms),clearTimeout:id=>timers.delete(id),setInterval:(fn,ms)=>timeout(fn,ms,ms),clearInterval:id=>timers.delete(id)}};
}
function channelFixture(){
 const c=clock(),writes=[],failures=[];let Channel,changes=0,wanted=false,resumedAt=null;
 class Socket{
  static OPEN=1;
  constructor(){this.readyState=1;this.bufferedAmount=0;queueMicrotask(()=>this.onopen?.());}
  emit(kind,sequence=0,payload=new Uint8Array()){this.onmessage?.({data:Channel.packet(kind,sequence,payload).buffer});}
  send(bytes){const kind=bytes[3],sequence=new DataView(bytes.buffer).getUint32(4);if(kind===0)queueMicrotask(()=>this.emit(1));else if(kind===6)queueMicrotask(()=>this.emit(7,0,bytes.slice(8)));else writes.push({kind,sequence,at:c.now});}
  close(){this.readyState=3;}
 }
 const context={window:{},location:new URL('https://flow.invalid/'),WebSocket:Socket,URL,TextEncoder,TextDecoder,Uint8Array,ArrayBuffer,DataView,queueMicrotask,...c.api};
 vm.runInNewContext(channelSource,context);Channel=context.window.AutoApproveInputChannel;
 const channel=new Channel('synthetic',{mode:'pty'},{onChange:()=>{changes++;if(wanted&&channel.canSend(1)){wanted=false;resumedAt=c.now;channel.send(2,new Uint8Array([1]));}},onFailure:error=>failures.push(error)});
 return {c,channel,writes,failures,get changes(){return changes;},get resumedAt(){return resumedAt;},want(){wanted=true;},reset(){changes=0;c.reset();}};
}
function screenFixture(http=false){
 const c=clock(),sent=[];let credit=true;
 const context={window:{},Uint8Array,DataView,TextEncoder,queueMicrotask,btoa:value=>Buffer.from(value,'binary').toString('base64'),...c.api};vm.runInNewContext(screenSource,context);
 const element={value:'',removeAttribute(){},hasPointerCapture(){return false;}};
 const control=new context.window.AutoApproveScreenControl({image:element,surface:element,keyboard:element,post:async(route,value)=>{if(route==='/api/screen/input'){sent.push(new Uint8Array(Buffer.from(value.payload,'base64')));return {accepted:true,sequence:value.sequence};}return {};}});control.state='ready';control.frameAt=0;control.share={id:'synthetic'};control.grant={controlID:'synthetic',token:'synthetic'};
 if(!http)control.channel={pendingCount:0,canSend:()=>credit,send:(kind,payload)=>{assert.equal(kind,8);sent.push(new Uint8Array(payload));queueMicrotask(()=>control.drain());return true;},close(){}};
 return {c,control,sent,credit:value=>{credit=value;if(value)queueMicrotask(()=>control.drain());}};
}
const burst=channelFixture();await burst.channel.open();await burst.c.flush();burst.reset();
for(let index=0;index<16;index++)assert.equal(burst.channel.send(2,new Uint8Array([index])),true);
await burst.c.flush();const burstMetrics={attemptedWrites:burst.writes.length,statusCallbacks:burst.changes,ackTimersCreated:burst.c.created};
assert.equal(burst.writes.length,16);assert.equal(burst.channel.pendingCount,16);
await burst.c.advance(19999);assert.equal(burst.channel.state,'ready');await burst.c.advance(2);assert.equal(burst.channel.state,'closed');assert.equal(burst.failures.length,1);assert.equal(burst.writes.length,16);

const blocked=channelFixture();await blocked.channel.open();await blocked.c.flush();blocked.channel.socket.bufferedAmount=64000;blocked.want();assert.equal(blocked.channel.canSend(1),false);
await blocked.c.advance(20);blocked.channel.socket.bufferedAmount=0;await blocked.c.advance(180);
const drainMetrics={writesAfterBufferDrained:blocked.writes.length,resumedAtMS:blocked.resumedAt};blocked.channel.close();assert.equal(blocked.c.timers.size,0);
const stuck=channelFixture();await stuck.channel.open();await stuck.c.flush();stuck.channel.socket.bufferedAmount=64000;assert.equal(stuck.channel.canSend(1),false);await stuck.c.advance(20100);
const stuckMetrics={state:stuck.channel.state,recoverable:stuck.failures[0]?.recoverable??null,writes:stuck.writes.length};stuck.channel.close();assert.equal(stuck.c.timers.size,0);

const integer=screenFixture(),fraction=screenFixture(),point={x:1000,y:2000};
for(let index=0;index<1000;index++){integer.control.wheel(point,0,1);fraction.control.wheel(point,0,0.2);await integer.c.advance(1);await fraction.c.advance(1);}
await integer.c.advance(16);await fraction.c.advance(16);
const sum=items=>items.reduce((total,payload)=>total+new DataView(payload.buffer).getInt16(7),0);
const wheelMetrics={integerEvents:1000,integerPackets:integer.sent.length,integerPixels:sum(integer.sent),fractionalEvents:1000,fractionalPackets:fraction.sent.length,fractionalPixels:sum(fraction.sent)};
integer.control.stop();fraction.control.stop();
if(baseline){assert.equal(burstMetrics.statusCallbacks,16);assert.equal(burstMetrics.ackTimersCreated,16);assert.equal(drainMetrics.writesAfterBufferDrained,0);assert.equal(stuckMetrics.state,'ready');assert.equal(wheelMetrics.integerPackets,1000);assert.equal(wheelMetrics.fractionalPixels,0);}
else{
 assert.equal(burstMetrics.statusCallbacks,1);assert.equal(burstMetrics.ackTimersCreated,1);assert.equal(drainMetrics.writesAfterBufferDrained,1);assert.ok(drainMetrics.resumedAtMS<=120);assert.equal(stuckMetrics.state,'closed');assert.equal(stuckMetrics.recoverable,true);assert.equal(stuckMetrics.writes,0);
 assert.ok(wheelMetrics.integerPackets<=64);assert.equal(wheelMetrics.integerPixels,1000);assert.equal(wheelMetrics.fractionalPixels,200);
 const pending=channelFixture();await pending.channel.open();await pending.c.flush();pending.channel.send(2,new Uint8Array([1]));pending.channel.socket.bufferedAmount=64000;assert.equal(pending.channel.canSend(1),false);await pending.c.advance(20100);
 assert.equal(pending.channel.state,'closed');assert.equal(pending.failures.length,1);assert.notEqual(pending.failures[0].recoverable,true);assert.equal(pending.writes.length,1);assert.equal(pending.channel.pendingCount,1);assert.equal(pending.c.timers.size,0);
 const oldest=channelFixture();await oldest.channel.open();await oldest.c.flush();oldest.channel.send(2,new Uint8Array([1]));await oldest.c.advance(1000);oldest.channel.send(2,new Uint8Array([2]));oldest.channel.socket.emit(4,1);await oldest.c.advance(19001);assert.equal(oldest.channel.state,'ready');await oldest.c.advance(1000);assert.equal(oldest.channel.state,'closed');assert.equal(oldest.writes.length,2);
 const closed=channelFixture();await closed.channel.open();await closed.c.flush();closed.channel.socket.bufferedAmount=64000;closed.want();assert.equal(closed.channel.canSend(1),false);closed.channel.close();closed.channel.socket.bufferedAmount=0;await closed.c.advance(1000);assert.equal(closed.writes.length,0);assert.equal(closed.failures.length,0);assert.equal(closed.c.timers.size,0);
 const split=screenFixture();split.credit(false);split.control.wheel(point,0,1500);split.control.wheel(point,0,1500);split.control.wheel(point,0,-100);
 split.control.wheel({...point,x:2000},0,50);split.control.wheel({...point,x:2000},0,50,2);split.control.text('한글🙂');
 split.credit(true);await split.c.advance(16);assert.deepEqual(split.sent.map(bytes=>bytes[0]),[3,3,3,3,3,4]);assert.deepEqual(split.sent.filter(bytes=>bytes[0]===3).map(bytes=>new DataView(bytes.buffer).getInt16(7)),[1500,1500,-100,50,50]);split.control.stop();
 const http=screenFixture(true);for(let index=0;index<1000;index++){http.control.wheel(point,0,0.2);await http.c.advance(1);}await http.c.advance(16);
 assert.equal(sum(http.sent),200);assert.ok(http.sent.length<=64);assert.equal(http.control.active,true);http.control.stop();assert.equal(http.c.timers.size,0);
}
console.log(JSON.stringify({passed:true,mode:baseline?'baseline-regression-reproduction':'candidate',burst:burstMetrics,drain:drainMetrics,stuck:stuckMetrics,wheel:wheelMetrics,scope:'Shipped JavaScript with deterministic socket-buffer/timer/ACK injection; actual Core/browser/Worker tests are separate.'}));
