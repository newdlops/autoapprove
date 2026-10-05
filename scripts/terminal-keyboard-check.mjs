// Isolated direct-key checks. No real app/window, permission prompt or event posts.
import {execFileSync} from 'node:child_process';
import {mkdtemp,readdir,rm,readFile,writeFile,mkdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const directory=await mkdtemp(path.join(tmpdir(),'autoapprove-terminal-keyboard-check-'));
try {
  const cache=path.resolve('.runtime/cache/TerminalKeyboardChecks');await mkdir(cache,{recursive:true});
  const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name));
  const binary=path.join(directory,'TerminalKeyboardChecks');
  const extra=process.argv.includes('--preflight-only')?['-D','KEYBOARD_PREFLIGHT_ONLY']:[];
  if(process.argv.includes('--isolated')){
    const source=await readFile('Sources/AutoApproveCore/TerminalAdapter.swift','utf8');
    const head='public struct ScreenTarget: Equatable, Sendable {';
    const declaration=source.split(head)[1]?.split('\n}\n')[0];
    if(!declaration)throw Error('The exact production ScreenTarget declaration was not found');
    const target=path.join(directory,'ScreenTarget.swift');await writeFile(target,'import TerminalInputSupport\n'+head+declaration+'\n}\n');
    extra.push('-D','TERMINAL_KEYBOARD_ISOLATED','-module-name','TerminalKeyboardIsolation','Sources/AutoApproveCore/RemoteTerminal.swift','Tests/fixtures/terminal-keyboard-isolation.swift',target);
  }
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,...extra,'Tests/fixtures/terminal-keyboard-check.swift','-o',binary],{stdio:'inherit'});
  execFileSync(binary,[],{stdio:'inherit',timeout:30000});
} finally {await rm(directory,{recursive:true,force:true});}
