// Launch the real MCP relay under synthetic agents with isolated fake bridges.
import {execFileSync} from 'node:child_process';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
const root=await mkdtemp('/private/tmp/aa-group-parent-');
try {
 const source=path.join(root,'parent.c');
 await writeFile(source,`#include <unistd.h>\n#include <sys/wait.h>\nint main(int argc,char **argv){pid_t p=fork();if(p<0)return 1;if(!p){execv(argv[1],argv+1);_exit(127);}int s;if(waitpid(p,&s,0)<0)return 1;return WIFEXITED(s)?WEXITSTATUS(s):1;}\n`);
 for(const agent of ['codex','claude']) {
  const binary=path.join(root,agent);
  execFileSync('/usr/bin/clang',[source,'-o',binary],{stdio:'inherit'});
  execFileSync(binary,[process.execPath,'scripts/session-groups-mcp-check.mjs','.build/debug/autoapprove'],
   {stdio:'inherit',env:{...process.env,AA_EXPECT_AGENT:'1'},timeout:30000});
  console.log(`PASS synthetic ${agent} parent attributed`);
 }
} finally {await rm(root,{recursive:true,force:true});}
