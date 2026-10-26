import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {coreLinkArguments} from './swift-core-link.mjs';

// Public Core APIs with synthetic address strings/interfaces only. The oracle
// uses Network's address parser; it does not copy the optimized byte parser.
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const build=path.resolve(option('build','.build/release')),sourceRoot=path.resolve(option('source-root','.'));
const fixture=path.resolve('Tests/fixtures/numeric-ipv4-check.swift');
const parent=path.resolve('.runtime/numeric-ipv4-check');fs.mkdirSync(parent,{recursive:true,mode:0o700});
const out=fs.mkdtempSync(parent+'/run-'),sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const objects=fs.readdirSync(build+'/AutoApproveCore.build').filter(name=>name.endsWith('.swift.o')).sort().map(name=>build+'/AutoApproveCore.build/'+name);
assert.ok(objects.length>0,'Build the matching release Core first');
const links=await coreLinkArguments(build),sources=['RemoteLAN.swift','RemoteHTTP.swift'].map(name=>path.join(sourceRoot,'Sources/AutoApproveCore',name));
const files=[...sources,fixture,path.resolve('scripts/numeric-ipv4-check.mjs'),build+'/Modules/AutoApproveCore.swiftmodule',...objects,...links.filter(file=>file.endsWith('.o'))];
const hashes=Object.fromEntries(files.map(file=>[file,sha(file)])),verify=()=>{for(const[file,digest]of Object.entries(hashes))assert.equal(sha(file),digest,file);};
const binary=out+'/check',cache=path.resolve(option('cache',out+'/module-cache'));
verify();execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...objects,fixture,'-o',binary],{stdio:'inherit',timeout:300000});verify();
const output=execFileSync(binary,[],{encoding:'utf8',timeout:120000,maxBuffer:1048576}),result=JSON.parse(output);verify();
assert.equal(result.passed,true);assert.equal(result.actualCoreLocalHostCases,631266);assert.equal(result.actualCoreRouteCases,10760);assert.equal(result.actualCoreEndpointCases,354);assert.equal(result.actualCoreOriginCases,4000);assert.ok(result.foreignStorageCases>0);
assert.equal(result.routeSelection.passed,true);assert.equal(result.routeSelection.cases,83120);assert.equal(result.routeSelection.consumerCases,1080);assert.equal(result.routeSelection.bindingCases,30);assert.ok(result.routeSelection.foreignInterfaceVisits>0);
fs.writeFileSync(out+'/report.json',JSON.stringify({...result,coreObjects:objects.length,inputs:hashes,binarySHA256:sha(binary),scope:'Numeric/foreign/Unicode/malformed host classification, endpoint/origin restrictions and unchanged route selection against independent Network-based oracle. No actual sockets, system settings, original terminal, installed app or mobile/whole-app speed claim.'},null,2)+'\n',{flag:'wx',mode:0o600});
console.log(JSON.stringify({...result,report:out+'/report.json'}));
