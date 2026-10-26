import { readdir, readFile } from 'node:fs/promises';
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

// A retained build may live at a different path than its original SwiftPM
// output map. Compare object basenames,then link only this build's files.
export async function coreSwiftObjects(build) {
  const directory=path.join(build,'AutoApproveCore.build');
  const [entries,text]=await Promise.all([readdir(directory),readFile(path.join(directory,'output-file-map.json'),'utf8')]);
  const map=JSON.parse(text),expected=[];
  for(const [source,output]of Object.entries(map)) {
    if(!source)continue;
    if(!source.endsWith('.swift')||typeof output?.object!=='string'||!output.object.endsWith('.swift.o'))throw new Error('Invalid Core output manifest');
    expected.push(path.basename(output.object));
  }
  if(!expected.length||new Set(expected).size!==expected.length)throw new Error('Empty or duplicate Core output manifest');
  expected.sort();const actual=entries.filter(name=>name.endsWith('.o')).sort();
  if(expected.length!==actual.length||expected.some((name,index)=>name!==actual[index]))throw new Error('Core objects do not match the build output manifest');
  return actual.map(name=>path.join(directory,name));
}
