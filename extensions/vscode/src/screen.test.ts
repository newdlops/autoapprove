import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ScreenMirror } from './screen';

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
