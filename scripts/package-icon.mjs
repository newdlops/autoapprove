import { mkdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

// The generated master stays untouched. sips makes only the required bundle sizes.
const source = path.resolve('assets/AppIcon.png');
const iconset = path.resolve('dist/AppIcon.iconset');
await mkdir(iconset, { recursive: true });
for (const size of [16, 32, 128, 256, 512]) {
  for (const scale of [1, 2]) {
    const pixels = String(size * scale);
    const name = `icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`;
    execFileSync('/usr/bin/sips', ['-z', pixels, pixels, source, '--out', path.join(iconset, name)], { stdio: 'pipe' });
  }
}
execFileSync('/usr/bin/iconutil', ['-c', 'icns', iconset, '-o', path.resolve('dist/AppIcon.icns')], { stdio: 'inherit' });
