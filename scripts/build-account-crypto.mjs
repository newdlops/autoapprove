// npm install --prefix <dependencies> --ignore-scripts --save-exact
// @noble/curves@2.4.0 @noble/ciphers@2.4.0 @noble/hashes@2.4.0 esbuild@0.25.12
import {readFile,writeFile,copyFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
const deps=path.resolve(process.argv[2]||'.runtime/agent-auth-196/dependencies');
const {build}=await import(deps+'/node_modules/esbuild/lib/main.js');
const vendor='Sources/AutoApproveCore/Resources/RemoteWeb/vendor';
const packages=['curves','ciphers','hashes'];const sources=[],lock=JSON.parse(await readFile(deps+'/package-lock.json'));
for(const name of packages){const dir=deps+'/node_modules/@noble/'+name,pkg=JSON.parse(await readFile(dir+'/package.json')),entry=lock.packages['node_modules/@noble/'+name];if(pkg.version!=='2.4.0'||entry.version!==pkg.version||!entry.integrity?.startsWith('sha512-'))throw Error('Unexpected crypto dependency version/integrity');await copyFile(dir+'/LICENSE',vendor+'/LICENSE-noble-'+name+'.txt');sources.push({package:'@noble/'+name,version:pkg.version,integrity:entry.integrity,source:'https://github.com/paulmillr/noble-'+name});}
await build({entryPoints:['scripts/agent-account-crypto.entry.mjs'],bundle:true,minify:true,platform:'browser',format:'iife',target:'es2020',nodePaths:[deps+'/node_modules'],outfile:vendor+'/account-crypto.js',legalComments:'eof'});
const data=await readFile(vendor+'/account-crypto.js');await writeFile(vendor+'/account-crypto.json',JSON.stringify({sources,bytes:data.length,sha256:createHash('sha256').update(data).digest('hex')},null,2)+'\n');console.log(JSON.stringify({bytes:data.length,sources}));
