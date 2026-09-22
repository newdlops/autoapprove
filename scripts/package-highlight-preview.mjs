import { mkdir, writeFile, readdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

const app = path.resolve('dist/qa/HighlightPreview.app');
await mkdir(path.join(app, 'Contents/MacOS'), { recursive: true });
execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-module-cache-path', path.resolve('.build/cache/HighlightPreview'),
  '-I', path.resolve('.build/release/Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3',
  ...(await readdir('.build/release/AutoApproveCore.build')).filter(name => name.endsWith('.swift.o')).map(name => path.resolve('.build/release/AutoApproveCore.build', name)),
  'Sources/AutoApproveApp/TerminalHighlighter.swift', 'Sources/AutoApproveApp/TerminalNavigator.swift', 'Sources/AutoApproveApp/QuestionNotifications.swift',
  'Sources/AutoApproveApp/AppHelp.swift', 'Sources/AutoApproveApp/AuditHistoryWindow.swift',
  'Sources/AutoApproveApp/SessionWindow.swift', 'Sources/AutoApproveApp/SessionCustomizationEditor.swift', 'Sources/AutoApproveApp/ConnectionSettings.swift', 'Tests/fixtures/highlight-preview.swift',
  '-o', path.join(app, 'Contents/MacOS/HighlightPreview')], { stdio: 'inherit' });
await writeFile(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.autoapprove.highlight-preview</string>
<key>CFBundleExecutable</key><string>HighlightPreview</string>
<key>CFBundleName</key><string>HighlightPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>`);
execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', app], { stdio: 'inherit' });
console.log(app);
