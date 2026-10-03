import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ScreenMirror } from './screen';
import { readThemeColors, resolveTerminalTheme } from './theme';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import * as path from 'node:path';

test('terminal themes inherit JSONC colors, apply scoped overrides and preserve light palettes', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'autoapprove-theme-'));
  try {
    await writeFile(path.join(directory, 'base.json'), '{ // theme comment\n"colors": {"terminal.ansiRed":"#123456", "panel.background":"#181818"}, }');
    await writeFile(path.join(directory, 'theme.json'), '{"include":"./base.json","colors":{"terminal.foreground":"#abc"}}');
    const colors = await readThemeColors(path.join(directory, 'theme.json'));
    const theme = resolveTerminalTheme(colors, { 'terminal.ansiRed': '#654321', '[Dark*][Another]': { 'terminal.ansiRed': '#fedcba' } }, 'Dark Theme', 2);
    assert.equal(theme.palette[1], '#fedcba'); assert.equal(theme.defaults.foreground, '#aabbcc');
    assert.equal(theme.defaults.background, '#181818');
    assert.equal(resolveTerminalTheme({}, {}, 'Light', 1).palette[2], '#107c10');
    assert.equal(resolveTerminalTheme({}, { 'terminal.foreground': 'url(bad)' }, 'Light', 1).defaults.foreground, '#333333');
    await writeFile(path.join(directory, 'base.json'), '{"include":"./theme.json","colors":{"terminal.background":"#000000"}}');
    assert.equal((await readThemeColors(path.join(directory, 'theme.json')))['terminal.background'], '#000000', 'Include cycles terminate');
  } finally { await rm(directory, { recursive: true, force: true }); }
  const mirror = new ScreenMirror(); await mirror.write('\x1b[1;31mbold red');
  assert.equal(mirror.appearance()!.runs[0].fg, '#f14c4c');
  assert.equal(mirror.appearance(undefined, {}, false)!.runs[0].fg, '#cd3131');
  mirror.dispose();
});

test('original ANSI colors and attributes survive cell extraction, Unicode and reset', async () => {
  const mirror = new ScreenMirror(); mirror.resize(80, 12);
  await mirror.write('\x1b[38;2;217;119;87;1mClaude 한글 🧪\x1b[0m plain\r\n\x1b[38;5;117;48;5;236;3;4;9mCodex\x1b[0m\r\n\x1b[7;2mreverse\x1b[0m\x1b[8mhidden\x1b[0m');
  const appearance = mirror.appearance()!;
  assert.deepEqual(appearance.runs[0], { offset: 0, length: 'Claude 한글 🧪'.length, fg: '#d97757', bold: true });
  const codex = appearance.runs.find(run => mirror.snapshot().slice(run.offset, run.offset + run.length) === 'Codex')!;
  assert.deepEqual({ fg: codex.fg, bg: codex.bg, italic: codex.italic, underline: codex.underline, strike: codex.strike },
    { fg: '#87d7ff', bg: '#303030', italic: true, underline: true, strike: true });
  assert.ok(appearance.runs.some(run => run.inverse && run.dim));
  assert.ok(appearance.runs.some(run => run.hidden));
  assert.equal(mirror.appearance(), appearance, 'Unchanged output reuses cell extraction');
  assert.ok(!appearance.runs.some(run => mirror.snapshot().slice(run.offset, run.offset + run.length).includes('plain')));
  await mirror.write('\x1b[2J\x1b[H\x1b[31mred\x1b[0m');
  assert.deepEqual(mirror.appearance()!.runs, [{ offset: 0, length: 3, fg: '#cd3131' }]);
  assert.equal(mirror.appearance(['#000000', '#123456'])!.runs[0].fg, '#123456', 'Explicit host palette applies');
  await mirror.write('\r\x1b[32mred\x1b[0m');
  assert.equal(mirror.appearance()!.runs[0].fg, '#0dbc79', 'Color-only repaint is retained');
  mirror.dispose();
});

test('ANSI appearance follows alternate screens and rejects pathological run counts', async () => {
  const mirror = new ScreenMirror(); mirror.resize(100, 100);
  await mirror.write('\x1b[31mmain\x1b[0m\x1b[?1049h\x1b[H\x1b[38;2;1;2;3malt\x1b[0m');
  assert.deepEqual(mirror.appearance()!.runs[0], { offset: 0, length: 3, fg: '#010203' });
  await mirror.write('\x1b[?1049l');
  assert.equal(mirror.appearance()!.runs[0].fg, '#cd3131');
  await mirror.write('\x1b[2J\x1b[H' + Array.from({ length: 9000 }, (_, i) => `\x1b[${i % 2 ? 31 : 32}mx`).join(''));
  assert.equal(mirror.appearance(), undefined, 'Excessive styles fall back to complete plain text');
  assert.ok(mirror.snapshot().includes('xxxxx'));
  mirror.dispose();
});

test('rendering accounts for cursor movements, erasure and alternate screens', async () => {
  const mirror = new ScreenMirror();
  mirror.resize(80, 24);
  await mirror.write('obsolete prompt\r\n');
  await mirror.write('\x1b[2J\x1b[HCurrent request\r\n1. Yes\r\n2. No');
  assert.ok(mirror.snapshot().startsWith('Current request\n1. Yes\n2. No'));
  assert.ok(!mirror.snapshot().includes('obsolete'));
  await mirror.write('\x1b[?1049h\x1b[HNew screen');
  assert.ok(mirror.snapshot().startsWith('New screen'));
  mirror.dispose();
});

test('approval is single-use, screen-bound, generation-bound and expiring', async () => {
  const mirror = new ScreenMirror();
  await mirror.write('request');
  const now = Date.now();
  const action = { id: 'a', fingerprint: mirror.fingerprint(), generation: mirror.generation, expiresAt: now + 1000, answer: '1' };
  assert.equal(mirror.consume({ ...action, generation: 'previous' }, now), false);
  assert.equal(mirror.consume({ ...action, expiresAt: now - 1 }, now), false);
  assert.equal(mirror.consume({ ...action, answer: '2' }, now), false);
  assert.equal(mirror.consume(action, now), true);
  assert.equal(mirror.consume(action, now), false);
  await mirror.write('\r\nChanged');
  assert.equal(mirror.consume({ ...action, id: 'b' }, now), false);
  mirror.invalidate();
  assert.equal(mirror.consume({ ...action, id: 'c', fingerprint: mirror.fingerprint() }, now), false);
  mirror.dispose();
});

test('unrendered data prevents approval of a stale snapshot', async () => {
  const mirror = new ScreenMirror();
  await mirror.write('request');
  const action = { id: 'a', fingerprint: mirror.fingerprint(), generation: mirror.generation, expiresAt: Date.now() + 1000, answer: '1' };
  const pending = mirror.write('\r\nnew prompt');
  assert.equal(mirror.consume(action), false);
  await pending;
  mirror.dispose();
});

test('active dialog tolerates changed history but validates command, selection and following text', async () => {
  const dialog = 'Would you like to run the following command?\n  $ echo 한글\n› 1. Yes, proceed (y)\n  2. No\nEnter to confirm';
  for (const [current, allowed] of [
    ['Changed history\n' + dialog, true],
    [dialog.replace('echo 한글', 'echo changed'), false],
    [dialog.replace('  $', ' $'), false],
    [dialog.replace('› 1.', '  1.'), false],
    [dialog + '\n› Next instruction', false]
  ] as const) {
    const mirror = new ScreenMirror();
    await mirror.write(current.replace(/\n/g, '\r\n'));
    const action = { id: 'dialog', fingerprint: 'old history hash', dialog, agent: 'codex', generation: mirror.generation, expiresAt: Date.now() + 1000, answer: '1' };
    assert.equal(mirror.consume(action), allowed);
    if (allowed) { assert.equal(mirror.consume(action), false, 'The same action remains single-use'); }
    mirror.dispose();
  }
});

test('Claude validates the command preceding the permission heading', async () => {
  const dialog = 'Bash command\n  echo first\nDo you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel';
  const mirror = new ScreenMirror();
  await mirror.write(dialog.replace('echo first', 'echo second').replace(/\n/g, '\r\n'));
  assert.equal(mirror.consume({ id: 'claude', fingerprint: '', dialog, agent: 'claude', generation: mirror.generation, expiresAt: Date.now() + 1000, answer: '1' }), false);
  mirror.dispose();
});

test('remote input requires the exact rendered screen and is never replayed', async () => {
  const mirror = new ScreenMirror();
  await mirror.write('› ready');
  const now = Date.now();
  const action = { id: 'remote-a', screen: mirror.snapshot(), generation: mirror.generation, expiresAt: now + 1000, kind: 'text', text: '한글 · input' };
  assert.equal(mirror.consumeInput({ ...action, generation: 'stale' }, now), false);
  assert.equal(mirror.consumeInput({ ...action, screen: 'other terminal' }, now), false);
  assert.equal(mirror.consumeInput({ ...action, expiresAt: now - 1 }, now), false);
  assert.equal(mirror.consumeInput({ ...action, text: '\x1b[3~' }, now), false);
  assert.equal(mirror.consumeInput({ ...action, text: '한'.repeat(3000) }, now), false);
  assert.equal(mirror.consumeInput(action, now), true);
  assert.equal(mirror.consumeInput(action, now), false);
  assert.equal(mirror.consumeInput({ ...action, id: 'key', kind: 'enter', text: '' }, now), true);
  for (const kind of ['submit', 'characters']) {
    const input = { ...action, id: kind, kind, text: '한글 🧪' };
    assert.equal(mirror.consumeInput({ ...input, text: 'bad\x03' }, now), false);
    assert.equal(mirror.consumeInput(input, now), true);
    assert.equal(mirror.consumeInput(input, now), false);
  }
  assert.equal(mirror.consumeInput({ ...action, id: 'paste', kind: 'submit', text: 'first\nsecond\tline' }, now), true);
  assert.equal(mirror.consumeInput({ ...action, id: 'raw-newline', kind: 'characters', text: 'first\nsecond' }, now), false);
  for (const kind of ['left', 'right', 'backspace', 'delete', 'home', 'end', 'escape', 'interrupt', 'up', 'down', 'tab']) {
    assert.equal(mirror.consumeInput({ ...action, id: kind, kind, text: 'hidden text' }, now), false);
    assert.equal(mirror.consumeInput({ ...action, id: kind, kind, text: '' }, now), true);
  }
  assert.equal(mirror.consumeInput({ ...action, id: 'unsupported', kind: 'deleteAll', text: '' }, now), false);
  const pending = mirror.write('\r\nchanged');
  assert.equal(mirror.consumeInput({ ...action, id: 'during-render' }, now), false);
  await pending;
  assert.equal(mirror.consumeInput({ ...action, id: 'old-frame' }, now), false);
  mirror.invalidate();
  assert.equal(mirror.consumeInput({ ...action, id: 'invalid', screen: mirror.snapshot() }, now), false);
  mirror.dispose();
});
