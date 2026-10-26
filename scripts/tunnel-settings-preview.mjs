import {execFileSync} from 'node:child_process';
import {readdir,mkdir} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/cloudflare-address/release'),out=path.resolve(option('output')||'.runtime/cf-address-187/native');await mkdir(out,{recursive:true,mode:0o700});
const objects=(await readdir(build+'/AutoApproveCore.build')).filter(v=>v.endsWith('.swift.o')).map(v=>build+'/AutoApproveCore.build/'+v),cache=path.resolve('.build/cache/TunnelSettingsPreview');await mkdir(cache,{recursive:true});
const binary=out+'/TunnelSettingsPreview';
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,
 'Sources/AutoApproveApp/WindowViewUpdates.swift','Sources/AutoApproveApp/QRCodeImageCache.swift','Sources/AutoApproveApp/CloudflareApprovalSteps.swift','Sources/AutoApproveApp/TunnelPINSettings.swift','Sources/AutoApproveApp/TunnelConnectionQuality.swift','Sources/AutoApproveApp/TunnelSettings.swift','Tests/AutoApproveCoreTests/CloudflareFixture.swift','Tests/AutoApproveCoreTests/WorkersFixture.swift','Tests/fixtures/tunnel-settings-preview.swift','-o',binary],{stdio:'inherit',timeout:300000});
execFileSync(binary,[out],{stdio:'inherit',timeout:20000});
