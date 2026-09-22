import { chmod, copyFile, mkdir, mkdtemp, readdir, readFile, readlink, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const dist = path.join(root, 'dist');
const app = path.resolve(process.argv[2] ?? path.join(dist, 'AutoApprove.app'));
const plist = path.join(app, 'Contents/Info.plist');
const readPlist = key => execFileSync('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, plist], { encoding: 'utf8' }).trim();
const version = readPlist('CFBundleShortVersionString');
if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`Invalid release version: ${version}`);

const architectures = binary => execFileSync('/usr/bin/lipo', ['-archs', path.join(app, 'Contents/MacOS', binary)], { encoding: 'utf8' }).trim().split(/\s+/).sort().join('-');
const architecture = architectures(readPlist('CFBundleExecutable'));
if (!['arm64', 'x86_64', 'arm64-x86_64'].includes(architecture) || architectures('autoapprove') !== architecture) {
  throw new Error('App and helper must have the same supported architectures');
}
const platform = architecture === 'arm64-x86_64' ? 'universal' : architecture;
const filename = `AutoApprove-${version}-macOS-${platform}.dmg`;
const output = path.join(dist, filename);
const installer = path.join(root, 'scripts/install.command');
// Finder can block a downloaded .command before its own xattr step runs.
// Distribute it as data for an explicit /bin/bash invocation, not a launcher.
const installerName = 'install.sh';
const guideName = '1. 설치 안내.txt';
const installCommand = `/bin/bash "/Volumes/AutoApprove ${version}/${installerName}"`;
const guide = (await readFile(path.join(root, 'docs/INSTALL.txt'), 'utf8'))
  .replaceAll('{{INSTALL_COMMAND}}', installCommand);
execFileSync('/bin/bash', ['-n', installer], { stdio: 'inherit' });
execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { stdio: 'inherit' });

const temporary = await mkdtemp(path.join(tmpdir(), 'autoapprove-dmg-'));
const staging = path.join(temporary, 'staging');
const image = path.join(temporary, filename);
const mounted = path.join(temporary, 'mounted');
let attached = false;
try {
  await mkdir(staging);
  await mkdir(mounted);
  execFileSync('/usr/bin/ditto', ['--noqtn', app, path.join(staging, 'AutoApprove.app')], { stdio: 'inherit' });
  await symlink('/Applications', path.join(staging, 'Applications'));
  await writeFile(path.join(staging, guideName), guide);
  await copyFile(installer, path.join(staging, installerName));
  await chmod(path.join(staging, installerName), 0o644);
  execFileSync('/usr/bin/hdiutil', ['create', '-volname', `AutoApprove ${version}`, '-srcfolder', staging, '-fs', 'HFS+', '-format', 'UDZO', '-imagekey', 'zlib-level=9', image], { stdio: 'inherit' });
  execFileSync('/usr/bin/hdiutil', ['verify', image], { stdio: 'inherit' });
  execFileSync('/usr/bin/hdiutil', ['attach', '-readonly', '-nobrowse', '-mountpoint', mounted, image], { stdio: 'inherit' });
  attached = true;
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', path.join(mounted, 'AutoApprove.app')], { stdio: 'inherit' });
  if (await readlink(path.join(mounted, 'Applications')) !== '/Applications') throw new Error('Invalid Applications shortcut');
  if ((await readFile(path.join(mounted, guideName), 'utf8')) !== guide || !guide.includes(installCommand)) {
    throw new Error('Installation instructions differ from source');
  }
  if (!(await readFile(path.join(mounted, installerName))).equals(await readFile(installer)) ||
      ((await stat(path.join(mounted, installerName))).mode & 0o111) !== 0) {
    throw new Error('Installer differs from source or is unexpectedly executable');
  }
  console.log(`Contents: ${(await readdir(mounted)).join(', ')}`);
  execFileSync('/usr/bin/hdiutil', ['detach', mounted], { stdio: 'inherit' });
  attached = false;
  await mkdir(dist, { recursive: true });
  await copyFile(image, output);
  const digest = createHash('sha256').update(await readFile(output)).digest('hex');
  await writeFile(`${output}.sha256`, `${digest}  ${filename}\n`);
  console.log(`DMG: ${output}\nSHA-256: ${digest}`);
} finally {
  if (attached) execFileSync('/usr/bin/hdiutil', ['detach', mounted], { stdio: 'inherit' });
  await rm(temporary, { recursive: true, force: true });
}
