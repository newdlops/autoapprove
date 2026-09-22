import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

const packageFile = path.resolve(process.argv[2] ?? 'dist/AutoApprove-0.2.25-macOS-arm64.pkg');
const root = await mkdtemp(path.join(tmpdir(), "autoapprove pkg 한글 '-"));
const expanded = path.join(root, 'expanded');
const exec = (command, args) => execFileSync(command, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
exec('/usr/sbin/pkgutil', ['--expand-full', packageFile, expanded]);
const component = path.join(expanded, 'AutoApprove.component.pkg');
const app = path.join(component, 'Payload/AutoApprove.app');
const quarantine = '0083;65000000;AutoApprove PKG check;';
const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
const attr = file => exec('/usr/bin/xattr', ['-p', 'com.apple.quarantine', file]);
const quarantineFile = file => exec('/usr/bin/xattr', ['-w', 'com.apple.quarantine', quarantine, file]);
const passed = result => assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);

async function fixture(shims = {}) {
  const directory = await mkdtemp(path.join(root, 'case-'));
  const destination = path.join(directory, 'Applications 테스트');
  const target = path.join(destination, 'AutoApprove.app');
  const launched = path.join(directory, 'launch-arguments');
  await mkdir(destination);
  exec('/usr/bin/ditto', [app, target]);
  const replacements = {
    '/bin/ps': 'exit 0',
    '/usr/bin/stat': 'printf "0\\n"',
    '/bin/launchctl': `printf '%s\\n' "$@" > ${quote(launched)}`,
    ...shims,
  };
  for (const [command, body] of Object.entries(replacements)) {
    const shim = path.join(directory, path.basename(command));
    await writeFile(shim, `#!/bin/bash\nset -eu\n${body}\n`);
    await chmod(shim, 0o755);
  }
  for (const script of ['common.sh', 'preinstall', 'postinstall']) {
    let source = await readFile(path.join(component, 'Scripts', script), 'utf8');
    // The shipped package has fixed system paths. Only isolated copies receive
    // a temporary install target and fault-injection tools; no root is needed.
    source = source.replace('install_root=/Applications', `install_root=${quote(destination)}`);
    for (const command of Object.keys(replacements)) source = source.replaceAll(command, quote(path.join(directory, path.basename(command))));
    await writeFile(path.join(directory, script), source);
  }
  const run = (script, volume = '/') => spawnSync('/bin/bash', [path.join(directory, script), packageFile, '/Applications', volume], { encoding: 'utf8', timeout: 15_000 });
  return { directory, destination, target, launched, run };
}

await test('Native Installer package', async t => {
  t.after(() => rm(root, { recursive: true, force: true }));

  await t.test('actual packaged payload has a valid signature and the fixed install location', async () => {
    exec('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
    const metadata = await readFile(path.join(component, 'PackageInfo'), 'utf8');
    assert.match(metadata, /install-location="\/Applications"/);
    assert.doesNotMatch(metadata, /<relocate>/);
    const distribution = await readFile(path.join(expanded, 'Distribution'), 'utf8');
    assert.match(distribution, /enable_currentUserHome="false"/);
    assert.match(distribution, /<must-close>/);
    const c = await fixture();
    passed(c.run('preinstall'));
    await rm(c.target, { recursive: true });
    passed(c.run('preinstall'));
  });

  await t.test('running app and unavailable process list stop installation', async () => {
    for (const body of ['printf "%s\\n" "/Volumes/AutoApprove 0.2.24/AutoApprove.app/Contents/MacOS/AutoApproveApp"', 'exit 1']) {
      const c = await fixture({ '/bin/ps': body });
      assert.equal(c.run('preinstall').status, 1);
      exec('/usr/bin/codesign', ['--verify', '--deep', '--strict', c.target]);
    }
  });

  await t.test('another bundle or a symlink is rejected before installation', async () => {
    const c = await fixture();
    exec('/usr/libexec/PlistBuddy', ['-c', 'Set :CFBundleIdentifier local.other.app', path.join(c.target, 'Contents/Info.plist')]);
    assert.equal(c.run('preinstall').status, 1);
    await rm(c.target, { recursive: true });
    await symlink(app, c.target);
    assert.equal(c.run('preinstall').status, 1);
    assert.equal(c.run('postinstall').status, 1);
  });

  await t.test('another volume is refused without changing the app', async () => {
    const c = await fixture();
    quarantineFile(c.target);
    assert.equal(c.run('preinstall', '/Volumes/Other').status, 1);
    assert.equal(c.run('postinstall', '/Volumes/Other').status, 1);
    assert.equal(attr(c.target), quarantine);
  });

  await t.test('quarantine is removed only from the installed app and nested files', async () => {
    const c = await fixture();
    const executable = path.join(c.target, 'Contents/MacOS/AutoApproveApp');
    for (const file of [c.target, executable]) quarantineFile(file);
    exec('/usr/bin/xattr', ['-w', 'local.autoapprove.pkg-test', 'keep', executable]);
    const other = path.join(c.directory, 'Other.app');
    await mkdir(other);
    quarantineFile(other);
    passed(c.run('postinstall'));
    assert.doesNotMatch(exec('/usr/bin/xattr', ['-r', '-s', c.target]), /com\.apple\.quarantine/);
    assert.equal(exec('/usr/bin/xattr', ['-p', 'local.autoapprove.pkg-test', executable]), 'keep');
    assert.equal(attr(other), quarantine);
    exec('/usr/bin/codesign', ['--verify', '--deep', '--strict', c.target]);
    await assert.rejects(readFile(c.launched), { code: 'ENOENT' });
    passed(c.run('postinstall'));
  });

  await t.test('a damaged installed bundle keeps its quarantine and is not opened', async () => {
    const c = await fixture();
    quarantineFile(c.target);
    await writeFile(path.join(c.target, 'Contents/Resources/autoapprove-bridge.vsix'), 'damaged');
    assert.equal(c.run('postinstall').status, 1);
    assert.equal(attr(c.target), quarantine);
    await assert.rejects(readFile(c.launched), { code: 'ENOENT' });
  });

  await t.test('quarantine failure reports installation failure without opening', async () => {
    const c = await fixture({ '/usr/bin/xattr': 'exit 1' });
    quarantineFile(c.target);
    assert.equal(c.run('postinstall').status, 1);
    assert.equal(attr(c.target), quarantine);
    await assert.rejects(readFile(c.launched), { code: 'ENOENT' });
  });

  await t.test('launch is delegated to the logged-in user and never root', async () => {
    const c = await fixture({ '/usr/bin/stat': 'printf "501\\n"' });
    passed(c.run('postinstall'));
    assert.deepEqual((await readFile(c.launched, 'utf8')).trim().split('\n'), ['asuser', '501', '/usr/bin/sudo', '-H', '-u', '#501', '--', '/usr/bin/open', c.target]);
  });

  await t.test('invalid console users and login window skip automatic opening', async () => {
    for (const uid of ['root', '0', '500']) {
      const c = await fixture({ '/usr/bin/stat': `printf '%s\\n' ${quote(uid)}` });
      passed(c.run('postinstall'));
      await assert.rejects(readFile(c.launched), { code: 'ENOENT' });
    }
  });

  await t.test('opening failure keeps a successful install and explains how to open the app', async () => {
    const c = await fixture({ '/usr/bin/stat': 'printf "501\\n"', '/bin/launchctl': 'exit 1' });
    const result = c.run('postinstall');
    passed(result);
    assert.match(result.stdout, /응용 프로그램 폴더에서 AutoApprove/);
    exec('/usr/bin/codesign', ['--verify', '--deep', '--strict', c.target]);
  });
});
