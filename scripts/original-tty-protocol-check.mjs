import {execFileSync} from 'node:child_process';
import {mkdir,rm,readdir} from 'node:fs/promises';
import path from 'node:path';
const output=path.resolve('.runtime/original-tty-protocol-check');
await mkdir(path.dirname(output),{recursive:true,mode:0o700});
try{
  execFileSync('/usr/bin/swift',['build','--target','TerminalInputSupport'],{stdio:'inherit'});
  const bin=execFileSync('/usr/bin/swift',['build','--show-bin-path'],{encoding:'utf8'}).trim();
  execFileSync('/usr/bin/swiftc',['-parse-as-library','-I',path.join(bin,'Modules'),'-I',path.join(bin,'CTTYInput.build'),
    'Tests/fixtures/original-tty-protocol-check.swift',...(await readdir(path.join(bin,'TerminalInputSupport.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(bin,'TerminalInputSupport.build',name)),
    path.join(bin,'CTTYInput.build/tty_input.c.o'),'-o',output],{stdio:'inherit'});
  execFileSync(output,[],{stdio:'inherit',timeout:10000});
}finally{await rm(output,{force:true});}
