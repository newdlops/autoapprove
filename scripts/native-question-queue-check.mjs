import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,readdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';

const build=path.resolve('.build/release'),directory=path.resolve('.runtime/native-question-queue-check');
await mkdir(directory,{recursive:true,mode:0o700});
const source=await readFile('Sources/AutoApproveApp/SessionWindow.swift','utf8');
const start=source.indexOf('struct CodexQuestionList:');
assert.ok(start>=0&&source.includes('struct CodexQuestionListDisplay:'));
const component=directory+'/ProductionQuestions.swift';
await writeFile(component,'import SwiftUI\nimport AutoApproveCore\n'+source.slice(start).replace(/private (?=(?:final class|struct) CodexQuestion)/g,''));
const cache=path.resolve('.build/cache/NativeQuestionQueueCheck');await mkdir(cache,{recursive:true});
const binary=directory+'/check';
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,
  '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
  ...(await readdir(build+'/AutoApproveCore.build')).filter(n=>n.endsWith('.swift.o')).map(n=>build+'/AutoApproveCore.build/'+n),
  'Sources/AutoApproveApp/AppHelp.swift',component,'Tests/fixtures/native-question-queue-check.swift','-o',binary],{stdio:'inherit',timeout:300000});
const report=JSON.parse(execFileSync(binary,[],{encoding:'utf8',timeout:15000}));
await writeFile(directory+'/report.json',JSON.stringify(report,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(report));
