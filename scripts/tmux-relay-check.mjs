// Creates only a private QA tmux server. Existing servers/CLI sessions are untouched.
import {execFileSync} from 'node:child_process';
import {mkdtemp, mkdir, readdir, rm, access} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const build = path.resolve('.build', process.argv.includes('--release') ? 'release' : 'debug');
const tmux = process.env.AUTOAPPROVE_TMUX || path.join(process.env.HOME, '.local/bin/tmux');
const directory = await mkdtemp(path.join(tmpdir(), 'aa-tmux-'));
const socket = path.join(directory, 'socket');
let created = false;
try {
  const cache = path.resolve('.build/cache/TmuxRelayChecks'); await mkdir(cache, {recursive:true});
  const objects = (await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name));
  const binary = path.join(directory,'TmuxRelayChecks');
  const pane = path.join(directory,'codex'), record = path.join(directory,'input.bin');
  execFileSync('/usr/bin/cc',['Tests/fixtures/tmux-relay-pane.c','-o',pane],{stdio:'inherit'});
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/tmux-relay-check.swift','-o',binary],{stdio:'inherit'});
  execFileSync(tmux,['-S',socket,'-f','/dev/null','new-session','-d','-x','80','-y','25','-s','qa',pane,record],{stdio:'inherit'});
  await access(socket); // tmux can report a sandbox bind failure with exit status zero.
  created = true;
  execFileSync(binary,[socket,tmux,record],{stdio:'inherit',timeout:30000});
} finally {
  if (created) { try { execFileSync(tmux,['-S',socket,'kill-server'],{stdio:'ignore',timeout:5000}); } catch {} }
  await rm(directory,{recursive:true,force:true});
}
