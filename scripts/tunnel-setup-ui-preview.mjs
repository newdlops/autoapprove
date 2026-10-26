import {mkdir,readdir,writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/cloudflare-address/release'),out=path.resolve(option('output')||'.runtime/cf-address-187');
const app=out+'/TunnelSetupPreview.app',mac=app+'/Contents/MacOS';await mkdir(mac,{recursive:true,mode:0o700});
const tools=out+'/ui-profile/tunnel-tools';await mkdir(tools,{recursive:true,mode:0o700});
execFileSync('/usr/bin/cc',['Tests/fixtures/tunnel-client.c','-o',tools+'/cloudflared']);
const objects=(await readdir(build+'/AutoApproveCore.build')).filter(v=>v.endsWith('.swift.o')).map(v=>build+'/AutoApproveCore.build/'+v);
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/TunnelSettingsPreview'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,
 'Sources/AutoApproveApp/WindowViewUpdates.swift','Sources/AutoApproveApp/QRCodeImageCache.swift','Sources/AutoApproveApp/CloudflareApprovalSteps.swift','Sources/AutoApproveApp/TunnelPINSettings.swift','Sources/AutoApproveApp/TunnelConnectionQuality.swift','Sources/AutoApproveApp/TunnelSettings.swift','Tests/AutoApproveCoreTests/CloudflareFixture.swift','Tests/AutoApproveCoreTests/WorkersFixture.swift','Tests/fixtures/tunnel-setup-ui.swift','-o',mac+'/TunnelSetupPreview'],{stdio:'inherit',timeout:300000});
await writeFile(app+'/Contents/Info.plist','<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.autoapprove.tunnel-setup-qa</string><key>CFBundleName</key><string>TunnelSetupPreview</string><key>CFBundleExecutable</key><string>TunnelSetupPreview</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>');
execFileSync('/usr/bin/open',['-g',app]);console.log('Started native Cloudflare setup interaction fixture: isolated empty profile, loopback only.');
