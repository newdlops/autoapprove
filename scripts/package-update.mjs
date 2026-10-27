import {execFileSync} from 'node:child_process';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
const app=path.resolve(process.argv[2]||'dist/AutoApprove.app'),out=path.resolve(process.argv[3]||'dist');
const release=JSON.parse(await readFile(app+'/Contents/Resources/AutoApprove_AutoApproveCore.bundle/RemoteWeb/web-version.json','utf8'));
if(!/^\d+\.\d+\.\d+$/.test(release.version)||!Number.isInteger(release.build)||release.build<1)throw Error('Invalid app release');
execFileSync('/usr/bin/codesign',['--verify','--deep','--strict',app],{stdio:'inherit'});
const arches=execFileSync('/usr/bin/lipo',['-archs',app+'/Contents/MacOS/AutoApproveApp'],{encoding:'utf8'}).trim().split(/\s+/);
if(!arches.length||arches.some(a=>!['arm64','x86_64'].includes(a)))throw Error('Unsupported architecture');
await mkdir(out,{recursive:true});
for(const arch of arches) {
 const name=`AutoApprove-${release.version}-build${release.build}-macOS-${arch}.zip`,file=path.join(out,name);
 execFileSync('/usr/bin/ditto',['-c','-k','--norsrc','--keepParent',app,file],{stdio:'inherit'});
 const bytes=await readFile(file);if(!bytes.length||bytes.length>32*1024*1024)throw Error('Update archive exceeds its size limit');
 const sha256=createHash('sha256').update(bytes).digest('hex');await writeFile(file+'.sha256',`${sha256}  ${name}\n`);
 console.log(JSON.stringify({name,bytes:bytes.length,sha256}));
}
