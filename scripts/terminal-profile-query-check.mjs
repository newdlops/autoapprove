// Count scripting API requests using production-generated scripts. No Terminal access.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';

const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/release');
const output=path.resolve(option('output')||'.runtime/terminal-profile-query-check/result.json');
await mkdir(path.dirname(output),{recursive:true});
const binary=path.join(path.dirname(output),'query-scripts');
let scripts;
if(option('scripts-file'))scripts=JSON.parse(await readFile(option('scripts-file'),'utf8'));
else {
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/ProfileQueryCheck'),
    '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),
    'Tests/fixtures/terminal-profile-query-scripts.swift','-o',binary],{stdio:'inherit',timeout:120000});
  scripts=JSON.parse(execFileSync(binary,[],{encoding:'utf8',timeout:10000}));
}
await writeFile(output+'.scripts.json',JSON.stringify(scripts)+'\n');

function check(scenario){
  let stats={},commands=[],activations=0,sleeps=0;
  const rawByTab=new WeakMap();
  const request=(name,read)=>{stats[name]=(stats[name]||0)+1;return read();};
  const windows=Array.from({length:scenario.existing},(_,index)=>({id:77+index,tabs:[{tty:'/dev/ttys'+(700+index)}]}));
  function tab(raw){
    const result={tty:()=>request('individualTTY',()=>raw.tty),busy:()=>request('busy',()=>false),processes:()=>request('processes',()=>['-zsh'])};
    rawByTab.set(result,raw);
    for(const name of ['currentSettings','customTitle'])Object.defineProperty(result,name,{set:value=>request(name,()=>{raw[name]=value;})});
    return result;
  }
  function window(raw){
    const tabs=()=>request('enumerateTabs',()=>raw.tabs.map(tab));
    tabs.whose=predicate=>()=>request('exactTTY',()=>raw.tabs.filter(value=>value.tty===predicate.tty).map(tab));
    const result={id:()=>request('windowID',()=>raw.id),exists:()=>request('exists',()=>windows.includes(raw)),tabs};
    for(const name of ['miniaturized','selectedTab','index'])Object.defineProperty(result,name,{set:value=>request(name,()=>{raw[name]=value;})});
    return result;
  }
  const list=()=>request('enumerateWindows',()=>windows.map(window));
  list.id=()=>request('bulkIDs',()=>windows.map(value=>value.id));
  list.tabs={tty:()=>request('bulkTTY',()=>windows.map(value=>value.tabs.map(value=>value.tty))),
    whose:predicate=>()=>request('exactTTY',()=>windows.map(value=>value.tabs.filter(value=>value.tty===predicate.tty).map(tab)))};
  list.byId=id=>{const raw=windows.find(value=>value.id===id);return raw?window(raw):{exists:()=>request('exists',()=>false)};};
  const profile={exists:()=>request('settingsExists',()=>true)};
  const app={windows:list,settingsSets:{byName:()=>profile},activate:()=>request('activate',()=>{activations++;}),
    doScript:(command,options)=>request('doScript',()=>{assert.ok(options?.in,'Never create a replacement window');commands.push({command,tty:rawByTab.get(options.in).tty});})};
  const context=vm.createContext({Application:()=>app,ObjC:{import:()=>{}},$:{NSThread:{sleepForTimeInterval:()=>{sleeps++;assert.fail('Ready shells must not sleep');}}}});
  const stages={};
  function run(stage){
    stats={};const text=vm.runInContext(scenario[stage],context,{timeout:2000});stages[stage]={...stats};return text;
  }
  const prepared=JSON.parse(run('prepare'));
  assert.equal(prepared.tty,scenario.anchor);assert.equal(prepared.windowID,77);assert.deepEqual(prepared.ttys,scenario.previous);
  windows.push({id:77+scenario.existing,tabs:[{tty:scenario.target}]});
  const confirmed=JSON.parse(run('confirm'));
  assert.equal(confirmed.tty,scenario.target);assert.equal(confirmed.windowID,77+scenario.existing);
  assert.equal(JSON.parse(run('launch')).tty,scenario.target);
  assert.equal(run('select'),'selected');assert.equal(commands.length,1);assert.equal(commands[0].tty,scenario.target);
  assert.equal(activations,3);assert.equal(sleeps,0);
  return {existing:scenario.existing,stages,requests:Object.values(stages).reduce((total,stage)=>total+Object.values(stage).reduce((a,b)=>a+b,0),0),commands};
}
const cases=scripts.map(check),recordOnly=process.argv.includes('--record-only');
if(!recordOnly){
  for(const result of cases){
    for(const stage of Object.values(result.stages)){
      assert.equal(stage.enumerateWindows||0,0);assert.equal(stage.enumerateTabs||0,0);
    }
    for(const name of ['prepare','confirm','select']){
      assert.equal(result.stages[name].bulkIDs,2);assert.equal(result.stages[name].bulkTTY,1);
    }
    assert.equal(result.stages.launch.exactTTY,1);assert.equal(result.stages.launch.processes,1);
    assert.equal(result.requests,cases[0].requests,'Client request count must stay fixed through 128 tabs');
  }
}
const report={label:option('label')||'current',actualTerminalOperations:0,measurement:'Synthetic scripting API request counts; excludes native AX and process startup, not elapsed time',cases};
if(option('baseline')){
  const baseline=JSON.parse(await readFile(option('baseline'),'utf8'));
  report.comparison=cases.map((result,index)=>{
    const before=baseline.cases[index];assert.equal(before.existing,result.existing);assert.deepEqual(before.commands,result.commands);
    if(result.existing>=20)assert.ok(result.requests<before.requests);
    return {existing:result.existing,before:before.requests,after:result.requests};
  });
}
await writeFile(output,JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report));
