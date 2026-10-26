import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {coreLinkArguments} from './swift-core-link.mjs';

// Links the actual release Core. Uses synthetic interfaces only; no listener,
// route changes, original terminal, input, permissions or installed app.
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const build=path.resolve(option('build','.build/release')),sourceRoot=path.resolve(option('source-root','.'));
const fixture=path.resolve('Tests/fixtures/peer-header-search-check.swift');
const parent=path.resolve('.runtime/peer-header-search-check');fs.mkdirSync(parent,{recursive:true,mode:0o700});
const out=fs.mkdtempSync(parent+'/run-'),sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const sources=['RemotePeerResponseDecoder.swift'].map(name=>path.join(sourceRoot,'Sources/AutoApproveCore',name));
const objects=fs.readdirSync(build+'/AutoApproveCore.build').filter(name=>name.endsWith('.swift.o')).sort().map(name=>build+'/AutoApproveCore.build/'+name);
assert.ok(objects.length>0,'Build the matching release Core first');
const links=await coreLinkArguments(build),inputs=[...sources,fixture,build+'/Modules/AutoApproveCore.swiftmodule',...objects,...links.filter(file=>file.endsWith('.o'))];
const hashes=Object.fromEntries(inputs.map(file=>[file,sha(file)]));
const verify=()=>{for(const[file,digest]of Object.entries(hashes))assert.equal(sha(file),digest,file);};
const binary=out+'/check',args=['swiftc','-O','-parse-as-library','-Xfrontend','-disable-access-control','-module-cache-path',out+'/module-cache',
  '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...objects,fixture,'-o',binary];
verify();execFileSync('/usr/bin/xcrun',args,{stdio:'inherit',timeout:180000});verify();
const output=execFileSync(binary,[],{encoding:'utf8',timeout:120000,maxBuffer:1048576});verify();
assert.match(output,/PEER_HEADER cases 1814; search-bound cases 14/);
assert.ok(output.includes('exact legacy bytes/errors/steps; caller storage exact'));
fs.writeFileSync(out+'/report.json',JSON.stringify({passed:true,summary:output.trim(),actualCompiledCore:true,coreObjects:objects.length,inputs:hashes,binarySHA256:sha(binary),
  scope:'Fragmented finite response equivalence, exact errors/steps/body/reuse, caller bytes and linear search ranges; no phone or whole-app speed claim',originalTerminalActions:0,realPowerCommands:0,installedAppReplaced:false},null,2)+'\n',{mode:0o600});
console.log(output.trim());
