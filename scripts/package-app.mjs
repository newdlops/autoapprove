import { mkdir, copyFile, writeFile, readFile, chmod, access, unlink, cp } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

const configuration = process.argv[2] ?? 'debug';
if (!['debug', 'release'].includes(configuration)) throw new Error('Expected debug or release');
const webVersion = JSON.parse(await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/web-version.json', 'utf8'));
const builtVersion = JSON.parse(await readFile(path.resolve('.build', configuration, 'AutoApprove_AutoApproveCore.bundle/RemoteWeb/web-version.json'), 'utf8'));
if (JSON.stringify(webVersion) !== JSON.stringify(builtVersion) || !/^\d+\.\d+\.\d+$/.test(webVersion.version) || !Number.isInteger(webVersion.build) || webVersion.build < 1) throw new Error('Build the current web resources before packaging');
await import('./package-icon.mjs');
const app = path.resolve(process.argv[3] ?? 'dist/AutoApprove.app');
const macOS = path.join(app, 'Contents/MacOS');
const resources = path.join(app, 'Contents/Resources');
await mkdir(macOS, { recursive: true });
await mkdir(resources, { recursive: true });
// Retire the original GUI name, which collided with the helper on case-insensitive APFS.
try { await unlink(path.join(macOS, 'AutoApprove')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
for (const binary of ['AutoApproveApp', 'autoapprove', 'AutoApproveTTYService']) {
  const source = path.resolve('.build', configuration, binary);
  await access(source);
  await copyFile(source, path.join(macOS, binary));
  await chmod(path.join(macOS, binary), 0o755);
}
await copyFile('dist/autoapprove-bridge.vsix', path.join(resources, 'autoapprove-bridge.vsix'));
await copyFile('dist/AppIcon.icns', path.join(resources, 'AppIcon.icns'));
await cp(path.resolve('.build', configuration, 'AutoApprove_AutoApproveCore.bundle'), path.join(resources, 'AutoApprove_AutoApproveCore.bundle'), { recursive: true });
const launchDaemons = path.join(app, 'Contents/Library/LaunchDaemons');
await mkdir(launchDaemons, { recursive: true });
await copyFile('scripts/resources/local.autoapprove.tty-input.plist', path.join(launchDaemons, 'local.autoapprove.tty-input.plist'));
await writeFile(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AutoApprove</string>
  <key>CFBundleDisplayName</key><string>AutoApprove</string>
  <key>CFBundleIdentifier</key><string>local.autoapprove.mac</string>
  <key>CFBundleExecutable</key><string>AutoApproveApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${webVersion.version}</string>
  <key>CFBundleVersion</key><string>${webVersion.build}</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>CFBundleLocalizations</key><array><string>ko</string></array>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>연결한 Terminal·iTerm2 세션의 승인 화면을 확인하고 해당 탭에 승인 입력을 전달합니다.</string>
  <key>NSScreenCaptureUsageDescription</key><string>사용자가 Mac 창 보기를 켤 때만 선택한 원본 터미널 창의 실제 화면과 커서를 같은 네트워크로 전달합니다.</string>
  <key>NSLocalNetworkUsageDescription</key><string>개인 핫스팟의 다른 AutoApprove Mac을 발견하고 휴대폰에서 세션 상태와 터미널을 관리합니다.</string>
  <key>NSBonjourServices</key><array><string>_autoapprove._tcp</string></array>
</dict></plist>
`);
await (await import('./sign-app.mjs')).signApp(app);
console.log(app);
