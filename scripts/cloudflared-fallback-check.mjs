// Opt-in real external transport check. Publishes only an isolated synthetic
// gateway through a temporary Quick Tunnel, then terminates its owned children.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readFile,writeFile,rm,stat} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/release'),out=path.resolve(option('output')||'.runtime/cloudflared-fallback-check');
const actual=option('cloudflared');assert.ok(actual&&path.isAbsolute(actual),'Pass --cloudflared=/absolute/path to the existing official binary');
assert.ok((await stat(actual)).isFile());
await mkdir(out,{recursive:true,mode:0o700});
const root=await mkdtemp('/private/tmp/aa-native-fallback-'),binary=out+'/check',wrapper=root+'/observed-cloudflared';
// The wrapper forwards the exact production argv and byte stream. Only fixed
// event names and elapsed numbers reach its private log; no connector text.
const python=`#!/usr/bin/python3
import json,os,pathlib,selectors,signal,subprocess,sys,time
actual=json.loads(${JSON.stringify(JSON.stringify(actual))})
event_path=json.loads(${JSON.stringify(JSON.stringify(root+'/events.jsonl'))})
child=None
def stop(signum=None,frame=None):
 if child is not None and child.poll() is None:
  child.terminate()
  try: child.wait(timeout=.1)
  except subprocess.TimeoutExpired:
   child.kill();child.wait(timeout=.05)
 if signum is not None: sys.exit(0)
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
child=subprocess.Popen([actual]+sys.argv[1:],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
started=time.monotonic();buffer=b'';selector=selectors.DefaultSelector();selector.register(child.stdout,selectors.EVENT_READ)
try:
 while child.poll() is None:
  for key,_ in selector.select(.2):
   data=os.read(key.fd,8192)
   if not data: break
   sys.stdout.buffer.write(data);sys.stdout.buffer.flush();buffer+=data
   while b'\\n' in buffer:
    line,buffer=buffer.split(b'\\n',1);text=line.decode('utf8','replace')
    kind=None
    if 'Switching to fallback protocol http2' in text:kind='fallback-http2'
    elif 'Registered tunnel connection' in text and 'protocol=quic' in text:kind='registered-quic'
    elif 'failed to dial to edge with quic' in text and 'timeout' in text:kind='quic-timeout'
    if kind:
     with open(event_path,'a') as output:output.write(json.dumps({'kind':kind,'seconds':round(time.monotonic()-started,3)})+'\\n')
finally:stop()
sys.exit(child.returncode or 0)
`;
await writeFile(wrapper,python,{mode:0o700});
let child,timer;
try{
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/NativeFallbackCheck'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/cloudflared-fallback.swift','-o',binary],{stdio:'inherit',timeout:180000});
 child=spawn(binary,[root,wrapper],{stdio:['ignore','pipe','pipe'],detached:true});
 child.stdout.resume();child.stderr.resume();
 timer=setTimeout(()=>{try{process.kill(-child.pid,'SIGTERM');}catch{}},75000);
 const status=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',resolve);});clearTimeout(timer);
 const report=JSON.parse(await readFile(root+'/report.json','utf8'));await writeFile(out+'/report.json',JSON.stringify(report,null,2)+'\n',{mode:0o600});
 console.log(JSON.stringify(report));assert.equal(status,0,'Native transport did not register QUIC or try HTTP2 within its readiness window');assert.equal(report.passed,true);
}finally{
 clearTimeout(timer);
 // This group contains only the fixture and its wrapper/official child. A
 // timeout or fixture crash must not leave a public temporary tunnel behind.
 if(child?.pid){try{process.kill(-child.pid,'SIGTERM');}catch{}await new Promise(resolve=>setTimeout(resolve,200));try{process.kill(-child.pid,'SIGKILL');}catch{}}
 await rm(root,{recursive:true,force:true});
}
