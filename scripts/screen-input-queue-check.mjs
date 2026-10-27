// High-rate pointer and backpressure tests of the shipped writer. No native
// events are posted and no actual WebSocket or desktop is used.
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const source=await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/screen-control.js','utf8');
const checks=[];
function fixture(){
 let now=0,next=0,credit=true;const timers=new Map(),sent=[];
 const timeout=(fn,ms)=>{const id=++next;timers.set(id,{fn,due:now+ms});return id;};
 const context={window:{},Uint8Array,DataView,TextEncoder,performance:{now:()=>now},queueMicrotask,setTimeout:timeout,clearTimeout:id=>timers.delete(id),clearInterval:id=>timers.delete(id)};
 vm.runInNewContext(source,context);const element={value:'',removeAttribute(){},hasPointerCapture(){return false;}};
 const control=new context.window.AutoApproveScreenControl({image:element,surface:element,keyboard:element,post:async()=>({})});control.state='ready';control.frameAt=0;
 control.channel={canSend:()=>credit,send:(kind,payload)=>{assert.equal(kind,8);sent.push({at:now,payload:[...payload]});queueMicrotask(()=>control.drain());return true;},close(){}};
 async function advance(ms){const end=now+ms;for(let n=0;n<10000;n++){const task=[...timers].filter(([,value])=>value.due<=end).sort((a,b)=>a[1].due-b[1].due)[0];if(!task)break;const[id,value]=task;now=value.due;timers.delete(id);value.fn();for(let i=0;i<8;i++)await Promise.resolve();}now=end;for(let i=0;i<8;i++)await Promise.resolve();}
 return {control,sent,advance,credit:value=>credit=value};
}
const rapid=fixture();
for(let index=0;index<1000;index++){assert.equal(rapid.control.move({x:index,y:200}),true);await rapid.advance(1);}
await rapid.advance(16);assert.equal(rapid.control.active,true);assert.ok(rapid.sent.length>=50&&rapid.sent.length<=64,'Fast ACK callbacks must not bypass pointer pacing');
assert.equal(rapid.sent.at(-1).payload[1]*256+rapid.sent.at(-1).payload[2],999);rapid.control.stop();
checks.push('1,000 pointer updates in one simulated second stay bounded at 50–64 packets and deliver the final coordinate even with immediate ACK callbacks');

const pressure=fixture();pressure.credit(false);
for(let index=0;index<63;index++)assert.equal(pressure.control.enqueue(new Uint8Array([5,0,0,0])),true);
assert.equal(pressure.control.move({x:1,y:1}),true);assert.equal(pressure.control.queue.length,64);
for(let index=0;index<100;index++)assert.equal(pressure.control.move({x:index,y:index}),true);
assert.equal(pressure.control.active,true);assert.equal(pressure.control.queue.length,64);
pressure.credit(true);await pressure.advance(16);assert.equal(pressure.sent.length,64);assert.equal(pressure.sent.at(-1).payload[2],99);pressure.control.stop();
checks.push('A full unsent window replaces its final motion without dropping earlier keys, stopping the connection, or growing memory');

const ordered=fixture();ordered.control.move({x:1,y:1});ordered.control.button(true,0,{x:2,y:2});ordered.control.text('한글🙂');ordered.control.button(false,0,{x:3,y:3});
await ordered.advance(100);assert.deepEqual(ordered.sent.map(value=>value.payload[0]),[0,1,4,2]);assert.ok(ordered.sent.every(value=>value.at===0),'Click, text and release must flush immediately without a pacing delay');ordered.control.stop();
checks.push('A click/text/button-up barrier flushes the latest earlier motion immediately and preserves the exact event order');
console.log(JSON.stringify({passed:true,checks,pointerPackets:rapid.sent.length,scope:'Production screen writer with deterministic timer/credit/ACK simulation; native and browser paths are checked separately'}));
