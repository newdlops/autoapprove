// All fixtures are synthetic. Do not alter the Mac's network or any user's agent session.
import {execFileSync} from 'node:child_process';
import path from 'node:path';

const configuration = process.argv.includes('--debug') ? 'debug' : 'release';
const profile = '(version 1)(allow default)(deny network*)(allow network* (local unix-socket) (remote unix-socket))';
const run = (binary, args) => execFileSync('/usr/bin/sandbox-exec', ['-p', profile, binary, ...args], {
  stdio: 'inherit', timeout: 180_000,
});
run(path.resolve('.build', configuration, 'autoapprove-checks'), ['--filter', 'Session groups:']);
run(process.execPath, [path.resolve('scripts/session-groups-mcp-check.mjs'), path.resolve('.build', configuration, 'autoapprove'), '--offline']);
console.log('PASS offline groups: IP networking denied; local identity, reconnect, messages and stdio survive');
