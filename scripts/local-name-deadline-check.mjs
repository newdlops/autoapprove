import {execFileSync} from 'node:child_process';
import {mkdir} from 'node:fs/promises';
import path from 'node:path';
const output=path.resolve('.build/qa');
await mkdir(output,{recursive:true});
const binary=path.join(output,'LocalNameDeadlineCheck');
execFileSync('/usr/bin/xcrun',['clang','-Wall','-Wextra','-I','Sources/CLocalDashboard/include','Tests/fixtures/local-name-deadline.c','-o',binary],{stdio:'inherit'});
execFileSync(binary,[],{stdio:'inherit',timeout:5000});
