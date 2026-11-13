import {execFileSync} from 'node:child_process';
import {mkdir,readFile,access} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3);
const build=path.resolve(option('build')||'.build/debug');
const out=path.resolve(option('output')||'/private/tmp/autoapprove-session-groups-render');
await mkdir(out,{recursive:true});
const binary=out+'/SessionGroupsRender';
const core=path.join(build,'AutoApproveCore.build');
const map=JSON.parse(await readFile(path.join(core,'output-file-map.json'),'utf8'));
const objects=Object.entries(map).filter(([source,value])=>source.endsWith('.swift') && typeof value.object==='string').map(([,value])=>path.join(core,path.basename(value.object)));
if (!objects.length || new Set(objects).size!==objects.length) throw new Error('Invalid core object map');
await Promise.all(objects.map(object=>access(object)));
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Sources/AutoApproveApp/SessionGroupsWindow.swift','Tests/fixtures/session-groups-render.swift','-o',binary],{stdio:'inherit',timeout:120000});
if (process.argv.includes('--interactive')) {
  execFileSync(binary,[out,'--interactive'],{stdio:'inherit',timeout:3600000});
} else console.log(execFileSync(binary,[out],{encoding:'utf8',timeout:30000}).trim());
