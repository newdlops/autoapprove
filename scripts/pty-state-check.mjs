import {execFileSync} from 'node:child_process';
import {mkdir,readdir} from 'node:fs/promises';
await mkdir('.build/pty-state',{recursive:true});
const vendor='Sources/CPTY/vendor/libvterm';
const sources=(await readdir(vendor+'/src')).filter(name=>name.endsWith('.c')).map(name=>vendor+'/src/'+name);
execFileSync('/usr/bin/cc',['-I','Sources/CPTY/include','-I',vendor+'/include','-I',vendor+'/src','Sources/CPTY/terminal.c',...sources,'Tests/fixtures/pty-terminal-check.c','-o','.build/pty-state/check'],{stdio:'inherit'});
execFileSync('.build/pty-state/check',[],{stdio:'inherit'});
