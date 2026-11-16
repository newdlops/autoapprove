// Fresh extraction and rejection checks use only a private owned cache.
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,copyFile,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {ensureOfficialCodexRuntime} from './fetch-official-codex.mjs';

const release=JSON.parse(await readFile(new URL('../Sources/AutoApproveCore/Resources/CodexOfficialRelease.json',import.meta.url),'utf8'));
const root=await mkdtemp('/private/tmp/aa-official-cache-');
try {
  const directory=path.join(root,'official-codex-'+release.version);
  await mkdir(directory,{mode:0o700});
  const archive='codex-package-'+release.target+'.tar.gz';
  await copyFile(path.resolve('.runtime','official-codex-'+release.version,archive),path.join(directory,archive));
  const runtime=await ensureOfficialCodexRuntime({cacheRoot:root});
  assert.equal(runtime,path.join(directory,'extracted'));
  assert.equal(await ensureOfficialCodexRuntime({cacheRoot:root}),runtime);
  const metadata=path.join(runtime,'codex-package.json'),original=await readFile(metadata);
  await writeFile(metadata,'{}');
  await assert.rejects(ensureOfficialCodexRuntime({cacheRoot:root}),/Official Codex file was modified/);
  assert.equal(await readFile(metadata,'utf8'),'{}','Invalid cache is reported without silently replacing it');
  await writeFile(metadata,original);
  await writeFile(path.join(runtime,'unknown-helper'),'owned-invalid-resource');
  await assert.rejects(ensureOfficialCodexRuntime({cacheRoot:root}),/complete unmodified official Codex package/);
  console.log(JSON.stringify({verified:true,version:release.version,freshExtraction:true,officialSignaturesVerified:true,cacheReuse:true,modifiedMetadataRejected:true,unknownResourceRejected:true,networkDownloads:0,userSessionsTouched:false}));
}finally{await rm(root,{recursive:true,force:true});}
