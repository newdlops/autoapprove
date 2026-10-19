// Independent UTF-8 oracle for the actual browser counter; synthetic strings only.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import {createHash} from 'node:crypto';
const app=await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/app.js','utf8');
const start=app.indexOf('const nonASCIIText = '),end=app.indexOf('\n};',start)+3;
assert.ok(start>=0&&end>start,'Locate the complete production counter and its ASCII predicate');
const source=app.slice(start,end),count=runInNewContext(source+';byteLength'),encoder=new TextEncoder();
let checks=0;
function check(value,limit) {
 const expected=encoder.encode(value).length,actual=count(value,limit);
 assert.equal(actual<=limit,expected<=limit,'The same UTF-8 limit must accept or reject the input');
 if(expected<=limit)assert.equal(actual,expected,'A permitted value needs its exact UTF-8 size');
 checks++;
}
const cases=[undefined,null,true,42,'','한글 e\u0301 🧪\r\n','\ud800','\udc00',
 String.fromCharCode(...Array.from({length:128},(_,index)=>index)).repeat(10),
 ...[255,256,257,7996,7997,7998,7999,8000,8001,31999,32000,32001].flatMap(length=>
  ['x'.repeat(length),'x'.repeat(length)+'한','x'.repeat(length)+'🧪','x'.repeat(length)+'\ud800']),
 'x'.repeat(1499999)+'\0','x'.repeat(1499999)+'한','한글🧪'.repeat(500000)];
for(const value of cases)for(const limit of [0,1,4,255,256,8000,32000,2000000,Infinity])check(value,limit);
let seed=79;
for(let sample=0;sample<5000;sample++) {
 let value='';
 for(let index=0;index<sample%2048;index++) {
  seed=(Math.imul(seed,1664525)+1013904223)|0;
  value+=String.fromCharCode(sample%2?seed>>>16:(seed>>>16)&127);
 }
 for(const limit of [0,32,8000,Infinity])check(value,limit);
}
console.log(JSON.stringify({result:'PASS',checks,sourceSHA256:createHash('sha256').update(source).digest('hex'),
 scope:'Actual production counter versus TextEncoder, all ASCII controls, NFD/emoji/lone surrogates, threshold boundaries and deterministic UTF-16 fuzz.'}));
