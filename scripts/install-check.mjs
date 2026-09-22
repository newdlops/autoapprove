import assert from 'node:assert/strict';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { chmod, mkdir, mkdtemp, readFile, readdir, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

const root = await mkdtemp(path.join(tmpdir(), 'autoapprove installer 한글 $-'));
const installer = await readFile(new URL('./install.command', import.meta.url), 'utf8');
const fixture = path.join(root, 'fixture.app');
await mkdir(path.join(fixture, 'Contents/MacOS'), { recursive: true });
await mkdir(path.join(fixture, 'Contents/Resources'));
await writeFile(path.join(fixture, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.autoapprove.mac</string>
<key>CFBundleExecutable</key><string>AutoApproveApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>`);
await writeFile(path.join(fixture, 'Contents/Resources/version.txt'), 'new');
execFileSync('/usr/bin/clang', ['-x', 'c', '-o', path.join(fixture, 'Contents/MacOS/AutoApproveApp'), '-'], {
  input: '#include <unistd.h>\nint main(int argc, char **argv) { if (argc > 1) { write(1, "ready\\n", 6); for (;;) pause(); } return 0; }\n',
});
execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', fixture], { stdio: 'pipe' });

const quarantine = '0081;65000000;AutoApprove installer check;';
const shellQuote = value => `'${value.replaceAll("'", "'\\''")}'`;
const exec = (command, args) => execFileSync(command, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
const attr = (file, name) => exec('/usr/bin/xattr', ['-p', name, file]);
const setAttr = (file, name, value) => exec('/usr/bin/xattr', ['-w', name, value, file]);

async function makeCase(name, replacements = {}) {
  const directory = await mkdtemp(path.join(root, `${name}-`));
  const app = path.join(directory, 'AutoApprove.app');
  const destination = path.join(directory, "Applications '테스트'");
  const target = path.join(destination, 'AutoApprove.app');
  const script = path.join(directory, '설치 및 실행.command');
  await mkdir(destination);
  exec('/usr/bin/ditto', [fixture, app]);
  let source = installer;
  for (const [command, body] of Object.entries(replacements)) {
    // Fault injection is confined to a generated test copy. The distributed
    // installer always uses absolute macOS tool paths and accepts no overrides.
    const shim = path.join(directory, path.basename(command));
    await writeFile(shim, `#!/bin/bash\nset -eu\n${body}\n`);
    await chmod(shim, 0o755);
    assert.ok(source.includes(command));
    source = source.replaceAll(command, shellQuote(shim));
  }
  await writeFile(script, source);
  const run = (options = ['--no-open']) => spawnSync('/bin/bash', [script, '--destination', destination, ...options], { encoding: 'utf8', timeout: 20_000 });
  const old = () => {
    exec('/usr/bin/ditto', [fixture, target]);
    return writeFile(path.join(target, 'Contents/Resources/version.txt'), 'old');
  };
  return { directory, app, destination, target, script, run, old };
}

function passed(result) {
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
}
async function onlyApp(context) {
  assert.deepEqual(await readdir(context.destination), ['AutoApprove.app']);
}
async function preserved(context) {
  assert.equal(await readFile(path.join(context.target, 'Contents/Resources/version.txt'), 'utf8'), 'old');
  await onlyApp(context);
}

await test('AutoApprove installer', async t => {
  t.after(() => rm(root, { recursive: true, force: true }));

  await t.test('quarantined app installs; nested quarantine is removed and other attributes and apps remain', async () => {
    const c = await makeCase('quarantine');
    const resource = path.join(c.app, 'Contents/Resources/version.txt');
    for (const file of [c.app, resource, path.join(c.app, 'Contents/MacOS/AutoApproveApp')]) setAttr(file, 'com.apple.quarantine', quarantine);
    setAttr(resource, 'local.autoapprove.installer-test', 'preserve me');
    const neighbor = path.join(c.directory, 'Other.app');
    await mkdir(neighbor);
    setAttr(neighbor, 'com.apple.quarantine', quarantine);
    passed(c.run());
    assert.doesNotMatch(exec('/usr/bin/xattr', ['-r', '-s', c.target]), /com\.apple\.quarantine/);
    assert.equal(attr(path.join(c.target, 'Contents/Resources/version.txt'), 'local.autoapprove.installer-test'), 'preserve me');
    assert.equal(attr(resource, 'com.apple.quarantine'), quarantine);
    assert.equal(attr(neighbor, 'com.apple.quarantine'), quarantine);
    exec('/usr/bin/codesign', ['--verify', '--deep', '--strict', c.target]);
    await onlyApp(c);
  });

  await t.test('repeat installation replaces the old app and works when quarantine is absent', async () => {
    const c = await makeCase('replace');
    await c.old();
    passed(c.run());
    passed(c.run());
    assert.equal(await readFile(path.join(c.target, 'Contents/Resources/version.txt'), 'utf8'), 'new');
    await onlyApp(c);
  });

  await t.test('damaged source is rejected before replacing the existing app', async () => {
    const c = await makeCase('damaged');
    await c.old();
    await writeFile(path.join(c.app, 'Contents/Resources/version.txt'), 'damaged');
    const result = c.run();
    assert.equal(result.status, 1);
    assert.match(result.stderr, /앱 파일 검사에 실패/);
    await preserved(c);
  });

  await t.test('a symlink target and a different bundle are not replaced', async () => {
    const c = await makeCase('symlink');
    await symlink(c.app, c.target);
    assert.equal(c.run().status, 1);
    await rm(c.target);
    await c.old();
    exec('/usr/libexec/PlistBuddy', ['-c', 'Set :CFBundleIdentifier local.other.app', path.join(c.target, 'Contents/Info.plist')]);
    assert.equal(c.run().status, 1);
    await preserved(c);
  });

  await t.test('an actual running destination app prevents replacement', async () => {
    const c = await makeCase('running');
    exec('/usr/bin/ditto', [fixture, c.target]);
    const child = spawn(path.join(c.target, 'Contents/MacOS/AutoApproveApp'), ['--wait'], { stdio: ['ignore', 'pipe', 'pipe'] });
    try {
      await once(child.stdout, 'data');
      const result = c.run();
      assert.equal(result.status, 1);
      assert.match(result.stderr, /실행 중인 AutoApprove/);
      await onlyApp(c);
    } finally {
      const ended = once(child, 'exit');
      child.kill();
      await ended;
    }
  });

  await t.test('failure during final replacement restores the old app', async () => {
    const c = await makeCase('rollback', {
      '/bin/mv': 'case "$1" in */.AutoApprove-install.*/AutoApprove.app) exit 1;; esac\nexec /bin/mv "$@"',
    });
    await c.old();
    const result = c.run();
    assert.equal(result.status, 1);
    assert.match(result.stderr, /기존 앱을 복원/);
    await preserved(c);
  });

  await t.test('cancelled administrator authentication leaves the old app intact', async () => {
    const c = await makeCase('cancel-auth', {
      '/usr/bin/xattr': 'exit 1',
      '/usr/bin/sudo': 'exit 1',
    });
    await c.old();
    const result = c.run();
    assert.equal(result.status, 1);
    assert.match(result.stderr, /관리자 인증을 완료하지 못했습니다/);
    await preserved(c);
  });

  await t.test('permission failure retries app-scoped xattr through sudo; no password is read by the script', async () => {
    const c = await makeCase('retry-auth', {
      '/usr/bin/xattr': 'if [[ ${INSTALL_CHECK_AUTHORIZED:-0} != 1 ]]; then exit 1; fi\nexec /usr/bin/xattr "$@"',
      '/usr/bin/sudo': 'if [[ $1 == -p ]]; then [[ $# == 3 && $3 == -v ]]; exit 0; fi\n[[ $1 == -n ]]\nshift\nexport INSTALL_CHECK_AUTHORIZED=1\nexec "$@"',
    });
    setAttr(c.app, 'com.apple.quarantine', quarantine);
    passed(c.run());
    assert.doesNotMatch(exec('/usr/bin/xattr', ['-r', '-s', c.target]), /com\.apple\.quarantine/);
    await onlyApp(c);
  });

  await t.test('protected existing app requests authentication before copying or replacing it', async () => {
    const c = await makeCase('protected-existing', { '/usr/bin/sudo': 'exit 1' });
    await c.old();
    const contents = path.join(c.target, 'Contents');
    await chmod(contents, 0o555);
    try {
      const result = c.run();
      assert.equal(result.status, 1);
      assert.match(result.stderr, /관리자 인증을 완료하지 못했습니다/);
      await preserved(c);
    } finally {
      await chmod(contents, 0o755);
    }
  });

  await t.test('another installer lock is preserved and prevents writes', async () => {
    const c = await makeCase('lock');
    await c.old();
    await mkdir(path.join(c.destination, '.AutoApprove-install.lock'));
    const result = c.run();
    assert.equal(result.status, 1);
    assert.match(result.stderr, /다른 설치가 진행 중/);
    assert.deepEqual((await readdir(c.destination)).sort(), ['.AutoApprove-install.lock', 'AutoApprove.app']);
  });

  await t.test('default flow hands the installed, cleared app to open as the current user', async () => {
    const c = await makeCase('launch', {
      '/bin/ps': 'exit 0',
      '/usr/bin/open': '[[ $EUID -ne 0 ]]\n/usr/bin/codesign --verify --deep --strict "$1"\n[[ $(/usr/bin/xattr -r -s "$1") != *com.apple.quarantine* ]]\nprintf "opened: %s\\n" "$1"',
    });
    setAttr(c.app, 'com.apple.quarantine', quarantine);
    const result = c.run([]);
    passed(result);
    assert.ok(result.stdout.includes(`opened: ${await realpath(c.target)}`));
    await onlyApp(c);
  });
});
