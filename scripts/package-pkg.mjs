import assert from 'node:assert/strict';
import { chmod, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const app = path.resolve(process.argv[2] ?? path.join(root, 'dist/AutoApprove.app'));
const plist = path.join(app, 'Contents/Info.plist');
const exec = (command, args) => execFileSync(command, args, { encoding: 'utf8' }).trim();
const value = key => exec('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, plist]);
const version = value('CFBundleShortVersionString');
assert.match(version, /^\d+\.\d+\.\d+$/);
assert.equal(value('CFBundleIdentifier'), 'local.autoapprove.mac');
assert.equal(value('CFBundleExecutable'), 'AutoApproveApp');
const architecture = binary => exec('/usr/bin/lipo', ['-archs', path.join(app, 'Contents/MacOS', binary)]).split(/\s+/).sort().join('-');
const arch = architecture('AutoApproveApp');
assert.ok(['arm64', 'x86_64', 'arm64-x86_64'].includes(arch));
assert.equal(architecture('autoapprove'), arch);
exec('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);

const name = `AutoApprove-${version}-macOS-${arch === 'arm64-x86_64' ? 'universal' : arch}.pkg`;
const output = path.join(root, 'dist', name);
const temporary = await mkdtemp(path.join(tmpdir(), 'autoapprove-pkg-'));
const identifier = 'local.autoapprove.mac.installer';
try {
  const payload = path.join(temporary, 'payload');
  const scripts = path.join(temporary, 'scripts');
  const resources = path.join(temporary, 'resources');
  for (const directory of [payload, scripts, resources]) await mkdir(directory);
  exec('/usr/bin/ditto', ['--noqtn', app, path.join(payload, 'AutoApprove.app')]);
  for (const script of ['common.sh', 'preinstall', 'postinstall']) {
    const source = path.join(root, 'scripts/pkg', script);
    exec('/bin/bash', ['-n', source]);
    await copyFile(source, path.join(scripts, script));
    await chmod(path.join(scripts, script), 0o755);
  }
  for (const page of ['welcome.html', 'conclusion.html']) {
    const source = await readFile(path.join(root, 'docs/installer', page), 'utf8');
    await writeFile(path.join(resources, page), source.replaceAll('{{VERSION}}', version));
  }
  const components = path.join(temporary, 'components.plist');
  await writeFile(components, `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><array><dict>
  <key>RootRelativeBundlePath</key><string>AutoApprove.app</string>
  <key>BundleIsRelocatable</key><false/>
  <key>BundleIsVersionChecked</key><true/>
  <key>BundleHasStrictIdentifier</key><true/>
  <key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>`);
  const component = path.join(temporary, 'AutoApprove.component.pkg');
  exec('/usr/bin/pkgbuild', ['--root', payload, '--component-plist', components, '--scripts', scripts,
    '--identifier', identifier, '--version', version, '--install-location', '/Applications', component]);
  const distribution = path.join(temporary, 'Distribution.xml');
  await writeFile(distribution, `<?xml version="1.0" encoding="UTF-8"?>
<installer-gui-script minSpecVersion="2">
  <title>AutoApprove ${version}</title>
  <welcome file="welcome.html" mime-type="text/html"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <options customize="never" require-scripts="false" hostArchitectures="${arch.replaceAll('-', ',')}"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <volume-check><allowed-os-versions><os-version min="14.0"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="autoapprove"/></choices-outline>
  <choice id="autoapprove" visible="false" title="AutoApprove"><pkg-ref id="${identifier}"/></choice>
  <pkg-ref id="${identifier}" version="${version}" onConclusion="None">AutoApprove.component.pkg</pkg-ref>
  <pkg-ref id="${identifier}"><must-close><app id="local.autoapprove.mac"/></must-close></pkg-ref>
</installer-gui-script>`);
  const packageFile = path.join(temporary, name);
  exec('/usr/bin/productbuild', ['--distribution', distribution, '--package-path', temporary, '--resources', resources, packageFile]);
  const expanded = path.join(temporary, 'expanded');
  exec('/usr/sbin/pkgutil', ['--expand-full', packageFile, expanded]);
  const expandedApp = path.join(expanded, 'AutoApprove.component.pkg/Payload/AutoApprove.app');
  exec('/usr/bin/codesign', ['--verify', '--deep', '--strict', expandedApp]);
  for (const binary of ['AutoApproveApp', 'autoapprove']) {
    assert.ok((await readFile(path.join(expandedApp, 'Contents/MacOS', binary))).equals(await readFile(path.join(app, 'Contents/MacOS', binary))));
  }
  for (const script of ['common.sh', 'preinstall', 'postinstall']) {
    assert.ok((await readFile(path.join(expanded, 'AutoApprove.component.pkg/Scripts', script))).equals(await readFile(path.join(scripts, script))));
  }
  for (const page of ['welcome.html', 'conclusion.html']) {
    assert.ok((await readFile(path.join(expanded, 'Resources', page))).equals(await readFile(path.join(resources, page))));
  }
  await mkdir(path.dirname(output), { recursive: true });
  await copyFile(packageFile, output);
  const digest = createHash('sha256').update(await readFile(output)).digest('hex');
  await writeFile(`${output}.sha256`, `${digest}  ${name}\n`);
  console.log(`PKG: ${output}\nSHA-256: ${digest}`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}
