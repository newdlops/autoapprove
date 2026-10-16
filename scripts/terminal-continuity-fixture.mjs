// Real Core transport with controllable synthetic originals. Shared by protocol
// and browser checks; never touches the installed app or a user's terminal.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdir,mkdtemp,readdir,readFile,writeFile,rm,stat} from 'node:fs/promises';
import {get} from 'node:http';
import {createGunzip} from 'node:zlib';
import {StringDecoder} from 'node:string_decoder';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
export const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
export async function until(test,label,timeout=10000){const end=performance.now()+timeout;while(!await test()){assert.ok(performance.now()<end,label);await wait(20);}}
export async function json(url,body,headers={}){
 const response=await fetch(url,{method:body?'POST':'GET',headers:{...(body?{'Content-Type':'application/json'}:{}),...headers},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(10000)});
 return {status:response.status,value:await response.json()};
}
export async function fixtureSuite(out,build=path.resolve('.build/release')){
 await mkdir(out,{recursive:true});const cache=path.resolve('.build/cache/Continuity');await mkdir(cache,{recursive:true});
 const supplied=process.argv.find(value=>value.startsWith('--preview='))?.slice(10);
 const binary=supplied?path.resolve(supplied):path.join(out,'TerminalContinuityPreview');
 const links=await coreLinkArguments(build),objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(v=>v.endsWith('.swift.o')).map(v=>path.join(build,'AutoApproveCore.build',v));
 if(supplied||process.argv.includes('--reuse-preview')){
  const built=(await stat(binary)).mtimeMs;
  for(const input of [...objects,...links.filter(v=>v.endsWith('.o')),path.join(build,'Modules/AutoApproveCore.swiftmodule'),'Tests/fixtures/terminal-continuity.swift'])assert.ok((await stat(input)).mtimeMs<=built,'Stale continuity preview: rebuild without --reuse-preview');
 }else execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...objects,
  'Tests/fixtures/terminal-continuity.swift','-o',binary],{stdio:'inherit',timeout:300000});
 const root=await mkdtemp('/private/tmp/aa-continuity-'),children=[],streams=[];
 return {
  async start(label){
   const child=spawn(binary,[path.join(root,label)],{stdio:['ignore','pipe','pipe']});children.push(child);
   let text='',stderr='',info;child.stdout.on('data',chunk=>{text+=chunk;for(const line of text.split('\n'))if(line.startsWith('{'))try{const v=JSON.parse(line);if(v.url)info=v;}catch{}});child.stderr.on('data',chunk=>stderr+=chunk);
   await until(()=>info||child.exitCode!==null||child.signalCode!==null,'Fixture startup '+label,20000);assert.ok(info,stderr);
   info.generation=0;return info;
  },
  async observe(node){return JSON.parse(await readFile(node.observations,'utf8'));},
  async control(node,value){
   const generation=++node.generation;await writeFile(node.control,JSON.stringify({...value,generation}));
   await until(async()=>{try{return JSON.parse(await readFile(node.observations,'utf8')).generation===generation;}catch{return false;}},'Fixture control acknowledgement');
  },
  stream(url,gzip=true){
   const result={events:[],wireBytes:0,decodedBytes:0,status:null,closed:false,error:null};streams.push(result);
   const decoder=new StringDecoder('utf8');let buffer='';
   const req=get(url,{headers:{'Accept-Encoding':gzip?'gzip':'identity'}},res=>{
    result.status=res.statusCode;result.encoding=res.headers['content-encoding'];
    res.on('data',chunk=>result.wireBytes+=chunk.length);
    const input=result.encoding==='gzip'?res.pipe(createGunzip()):res;
    input.on('data',chunk=>{
     result.decodedBytes+=chunk.length;buffer+=decoder.write(chunk);let boundary;
     while((boundary=buffer.indexOf('\n\n'))>=0){
      const text=buffer.slice(0,boundary);buffer=buffer.slice(boundary+2);const lines=text.split('\n');
      const type=lines.find(v=>v.startsWith('event: '))?.slice(7),data=lines.filter(v=>v.startsWith('data: ')).map(v=>v.slice(6)).join('\n');
      if(type)try{result.events.push({type,value:JSON.parse(data),bytes:Buffer.byteLength(text)+2,at:performance.now()});}catch(e){result.error=e;}
     }
     if(buffer.length>2_100_000)result.close();
    });
    input.on('error',e=>{if(!result.closed)result.error=e;});res.on('error',e=>{if(!result.closed)result.error=e;});
   });
   req.on('error',e=>{if(!result.closed)result.error=e;});
   result.close=()=>{result.closed=true;req.destroy();};
   result.event=async(predicate,from=0,timeout=10000)=>{
    await until(()=>result.events.slice(from).some(predicate)||result.error,'Expected SSE event '+url,timeout);if(result.error)throw result.error;return result.events.slice(from).find(predicate);
   };
   return result;
  },
  async stop(){
   for(const stream of streams)stream.close();for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill();
   await Promise.all(children.map(child=>child.exitCode!==null||child.signalCode!==null?null:new Promise(resolve=>child.once('exit',resolve))));
   await rm(root,{recursive:true,force:true});
  }
 };
}
