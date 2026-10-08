// Dedicated QA server and owned PTY only; no existing user terminal is touched.
import {execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,readdir,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug'),root=await mkdtemp('/private/tmp/aa-interruption-relay-'),socket=path.join(root,'socket');
const tmux=process.env.AUTOAPPROVE_TMUX||path.join(process.env.HOME,'.local/bin/tmux');let started=false;
try{
 await mkdir('.build/cache/InterruptionRelay',{recursive:true});
 execFileSync('/usr/bin/cc',['Tests/fixtures/interruption-pane.c','-o',path.join(root,'codex')],{stdio:'inherit'});
 const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(f=>f.endsWith('.swift.o')).map(f=>path.join(build,'AutoApproveCore.build',f));
 const binary=path.join(root,'check');execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/InterruptionRelay'),'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/interruption-relay-check.swift','-o',binary],{stdio:'inherit'});
 execFileSync(tmux,['-S',socket,'-f','/dev/null','new-session','-d','-x','100','-y','25','-s','qa','/bin/zsh -f'],{stdio:'inherit'});started=true;
 execFileSync(binary,[root,socket,tmux],{stdio:'inherit',timeout:30000});
}finally{if(started){try{execFileSync(tmux,['-S',socket,'kill-server'],{stdio:'ignore'});}catch{}}await rm(root,{recursive:true,force:true});}
