import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {coreLinkArguments} from './swift-core-link.mjs';

// Requires a matching release Core build. All sessions and text are synthetic;
// this never starts the app, a network listener or an original terminal.
export async function runCanonicalFixture(kind){
  assert.ok(['json','response'].includes(kind));
  const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
  const build=path.resolve(option('build','.build/release'));
  const source=path.resolve(option('source','Sources/AutoApproveCore/RemoteDashboardResponse.swift'));
  const fixture=path.resolve(option('fixture','Tests/fixtures/canonical-'+kind+'-check.swift'));
  const parent=path.resolve('.runtime/canonical-'+kind+'-check');fs.mkdirSync(parent,{recursive:true});
  const out=fs.mkdtempSync(parent+'/run-'),sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  const objects=fs.readdirSync(build+'/AutoApproveCore.build').filter(name=>name.endsWith('.swift.o')).sort().map(name=>build+'/AutoApproveCore.build/'+name);
  assert.ok(objects.length>0,'Build release Core before running this check');
  const links=await coreLinkArguments(build),inputs=[source,fixture,build+'/Modules/AutoApproveCore.swiftmodule',...objects,...links.filter(file=>file.endsWith('.o'))];
  const hashes=Object.fromEntries(inputs.map(file=>[file,sha(file)]));
  const verify=()=>{for(const[file,digest]of Object.entries(hashes))assert.equal(sha(file),digest,file)};
  let swift=fixture;
  if(kind==='json'){
    const body=fs.readFileSync(source,'utf8'),marker='// Foundation has legacy framework modes with different object-key ordering.';
    assert.equal(body.split(marker).length,2,'Canonical JSON implementation not found');
    swift=out+'/fixture.swift';fs.writeFileSync(swift,'import Foundation\nimport Darwin\n'+body.slice(body.indexOf(marker))+'\n'+fs.readFileSync(fixture,'utf8'));
  }
  const binary=out+'/check',args=['swiftc','-O','-parse-as-library','-module-name','profile','-module-cache-path',out+'/module-cache','-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...objects,swift,'-o',binary];
  verify();execFileSync('/usr/bin/xcrun',args,{stdio:'inherit',timeout:180000});verify();
  const output=execFileSync(binary,[],{encoding:'utf8',timeout:240000,maxBuffer:1048576});verify();
  if(kind==='json'){
    assert.match(output,/JSON_COMPATIBILITY modern (true|false); incompatible false; explicit fallback exact; reference error preserved; unsupported formatting false/);
    assert.match(output,/TRANSIENT_JSON scalars 1112064; utf16Units 65536; cases \d+; foreign \d+; models 24; checksum \d+/);
    assert.match(output,/JSON_KEY_STORAGE scalars 1112064; utf16Units 65536; cases \d+; foreign \d+; checksum \d+/);
  }else{
    assert.match(output,/CANONICAL_RESPONSE_API scalars 1112064; utf16Units 65536; frames 14604; foreign \d+; checks 45727; checksum \d+/);
  }
  fs.writeFileSync(out+'/report.json',JSON.stringify({passed:true,kind,summary:output.trim(),coreObjects:objects.length,inputs:hashes,originalTerminalActions:0,realPowerCommands:0},null,2)+'\n');
  console.log(output.trim());
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))await runCanonicalFixture('json');
