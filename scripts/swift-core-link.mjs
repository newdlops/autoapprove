import { readdir } from 'node:fs/promises';
import path from 'node:path';

// Swift fixture executables link the core's C terminal implementation as well.
export async function coreLinkArguments(build) {
  async function objects(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    return (await Promise.all(entries.map(entry => entry.isDirectory() ? objects(path.join(directory, entry.name)) : entry.name.endsWith('.o') ? [path.join(directory, entry.name)] : []))).flat();
  }
  return ['-I', path.resolve('Sources/CPTY/include'), '-I', path.join(build, 'CTTYInput.build'),
    '-I', path.join(build, 'CLocalDashboard.build'),
    ...await objects(path.join(build, 'CPTY.build')), ...await objects(path.join(build, 'CTTYInput.build')),
    ...await objects(path.join(build, 'CLocalDashboard.build')),
    ...await objects(path.join(build, 'TerminalInputSupport.build'))];
}
