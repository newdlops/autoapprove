import { copyFile, mkdir, readdir, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

const configuration = process.argv[2] ?? 'debug';
if (!['debug', 'release'].includes(configuration)) throw new Error('Expected debug or release');
const build = path.resolve('.build', configuration);
const app = path.resolve('dist/qa/SessionPreview.app');
await mkdir(path.join(app, 'Contents/MacOS'), { recursive: true });
await mkdir(path.join(app, 'Contents/Resources'), { recursive: true });
await copyFile('dist/AppIcon.icns', path.join(app, 'Contents/Resources/AppIcon.icns'));
execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-module-cache-path', path.resolve('.build/cache/SessionPreview'),
  '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3',
  ...(await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o')).map(name => path.join(build, 'AutoApproveCore.build', name)),
  'Sources/AutoApproveApp/TerminalHighlighter.swift', 'Sources/AutoApproveApp/TerminalNavigator.swift',
  'Sources/AutoApproveApp/AppHelp.swift', 'Sources/AutoApproveApp/AuditHistoryWindow.swift',
  'Sources/AutoApproveApp/AppInformation.swift', 'Sources/AutoApproveApp/AppCommands.swift', 'Sources/AutoApproveApp/HelpWindow.swift',
  'Sources/AutoApproveApp/SessionWindow.swift', 'Sources/AutoApproveApp/SessionCustomizationEditor.swift', 'Sources/AutoApproveApp/ConnectionSettings.swift',
  'Tests/fixtures/session-preview.swift', '-o', path.join(app, 'Contents/MacOS/SessionPreview')], { stdio: 'inherit' });
await writeFile(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.autoapprove.session-preview</string>
<key>CFBundleExecutable</key><string>SessionPreview</string>
<key>CFBundleName</key><string>SessionPreview</string>
<key>CFBundleShortVersionString</key><string>0.2.22</string>
<key>CFBundleVersion</key><string>26</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>ko</string>
<key>CFBundleLocalizations</key><array><string>ko</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>`);
execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', app], { stdio: 'inherit' });
console.log(app);
