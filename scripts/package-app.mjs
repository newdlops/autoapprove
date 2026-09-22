import { mkdir, copyFile, writeFile, chmod, access, unlink } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

const configuration = process.argv[2] ?? 'debug';
if (!['debug', 'release'].includes(configuration)) throw new Error('Expected debug or release');
await import('./package-icon.mjs');
const app = path.resolve(process.argv[3] ?? 'dist/AutoApprove.app');
const macOS = path.join(app, 'Contents/MacOS');
const resources = path.join(app, 'Contents/Resources');
await mkdir(macOS, { recursive: true });
await mkdir(resources, { recursive: true });
// Retire the original GUI name, which collided with the helper on case-insensitive APFS.
try { await unlink(path.join(macOS, 'AutoApprove')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
for (const binary of ['AutoApproveApp', 'autoapprove']) {
  const source = path.resolve('.build', configuration, binary);
  await access(source);
  await copyFile(source, path.join(macOS, binary));
  await chmod(path.join(macOS, binary), 0o755);
}
await copyFile('dist/autoapprove-bridge.vsix', path.join(resources, 'autoapprove-bridge.vsix'));
await copyFile('dist/AppIcon.icns', path.join(resources, 'AppIcon.icns'));
await writeFile(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AutoApprove</string>
  <key>CFBundleDisplayName</key><string>AutoApprove</string>
  <key>CFBundleIdentifier</key><string>local.autoapprove.mac</string>
  <key>CFBundleExecutable</key><string>AutoApproveApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.22</string>
  <key>CFBundleVersion</key><string>26</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>CFBundleLocalizations</key><array><string>ko</string></array>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>선택한 Terminal 세션의 승인 화면을 확인하고 해당 탭에 승인 입력을 전달합니다.</string>
</dict></plist>
`);
execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--identifier', 'local.autoapprove.helper', path.join(macOS, 'autoapprove')], { stdio: 'inherit' });
execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--entitlements', 'scripts/entitlements.plist', app], { stdio: 'inherit' });
console.log(app);
