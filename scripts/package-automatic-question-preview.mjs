import { mkdir, readdir, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

const app = path.resolve('dist/qa/AutomaticQuestionPreview.app');
await mkdir(path.join(app, 'Contents/MacOS'), { recursive: true });
execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-module-cache-path', path.resolve('.build/cache/AutomaticQuestionPreview'),
  '-I', path.resolve('.build/debug/Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3',
  ...(await readdir('.build/debug/AutoApproveCore.build')).filter(name => name.endsWith('.swift.o')).map(name => path.resolve('.build/debug/AutoApproveCore.build', name)),
  'Sources/AutoApproveApp/TerminalHighlighter.swift', 'Sources/AutoApproveApp/TerminalNavigator.swift',
  'Sources/AutoApproveApp/AppHelp.swift', 'Sources/AutoApproveApp/AuditHistoryWindow.swift',
  'Sources/AutoApproveApp/SessionWindow.swift', 'Sources/AutoApproveApp/ConnectionSettings.swift',
  'Tests/fixtures/automatic-question-preview.swift', '-o', path.join(app, 'Contents/MacOS/AutomaticQuestionPreview')], { stdio: 'inherit' });
await writeFile(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.autoapprove.automatic-question-preview</string>
<key>CFBundleExecutable</key><string>AutomaticQuestionPreview</string>
<key>CFBundleName</key><string>AutomaticQuestionPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>`);
execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', app], { stdio: 'inherit' });
console.log(app);
