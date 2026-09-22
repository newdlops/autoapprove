import { copyFile, mkdir, mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises';
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
// Ship one primary action: the native macOS Installer package.
execFileSync(process.execPath, [path.join(root, 'scripts/package-pkg.mjs'), app], { stdio: 'inherit' });
const installer = path.join(dist, `AutoApprove-${version}-macOS-${platform}.pkg`);
const installerName = 'AutoApprove 설치.pkg';
const guideName = '설치 안내.txt';
const guide = await readFile(path.join(root, 'docs/INSTALL.txt'), 'utf8');
execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { stdio: 'inherit' });

const temporary = await mkdtemp(path.join(tmpdir(), 'autoapprove-dmg-'));
const staging = path.join(temporary, 'staging');
const image = path.join(temporary, filename);
const mounted = path.join(temporary, 'mounted');
let attached = false;
try {
  await mkdir(staging);
  await mkdir(mounted);
  await writeFile(path.join(staging, guideName), guide);
  await copyFile(installer, path.join(staging, installerName));
  execFileSync('/usr/bin/hdiutil', ['create', '-volname', `AutoApprove ${version}`, '-srcfolder', staging, '-fs', 'HFS+', '-format', 'UDZO', '-imagekey', 'zlib-level=9', image], { stdio: 'inherit' });
  execFileSync('/usr/bin/hdiutil', ['verify', image], { stdio: 'inherit' });
  execFileSync('/usr/bin/hdiutil', ['attach', '-readonly', '-nobrowse', '-mountpoint', mounted, image], { stdio: 'inherit' });
  attached = true;
  if ((await readFile(path.join(mounted, guideName), 'utf8')) !== guide) {
    throw new Error('Installation instructions differ from source');
  }
  if (!(await readFile(path.join(mounted, installerName))).equals(await readFile(installer))) {
    throw new Error('Installer differs from the verified package');
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
