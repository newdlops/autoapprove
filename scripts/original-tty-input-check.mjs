import {execFileSync} from 'node:child_process';
import {mkdir,rm} from 'node:fs/promises';
import path from 'node:path';

const output=path.resolve('.runtime/original-tty-input-check');
await mkdir(path.dirname(output),{recursive:true,mode:0o700});
try{
  execFileSync('/usr/bin/clang',['-std=c11','-Wall','-Wextra','-Werror','-O2','-ISources/CTTYInput/include',
    'Tests/fixtures/original-tty-input-check.c','Sources/CTTYInput/tty_input.c','-o',output],{stdio:'inherit'});
  execFileSync(output,[],{stdio:'inherit',timeout:15000});
}finally{await rm(output,{force:true});}
