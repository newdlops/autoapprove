import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NativeTerminalBinding } from './native-input';

test('native reveal refuses stale, duplicate and expired requests before activating a window', () => {
  const binding = new NativeTerminalBinding();
  const now = Date.now();
  const request = { id: 'connect', generation: binding.generation, expiresAt: now + 1000 };
  assert.equal(binding.beginReveal({ ...request, generation: 'retired' }, now), undefined);
  assert.equal(binding.beginReveal({ ...request, expiresAt: now - 1 }, now), undefined);
  const valid = binding.beginReveal(request, now);
  assert.ok(valid); assert.equal(valid!(now), true);
  assert.equal(binding.beginReveal(request, now), undefined);
  binding.disconnect();
  assert.equal(valid!(now), false, 'Disconnect cancels activation still waiting for focus');
});

test('existing original terminal input needs an explicit source confirmation', () => {
  const binding = new NativeTerminalBinding();
  const now = Date.now();
  const action = () => ({ id: 'original', generation: binding.generation, expiresAt: now + 1000, kind: 'characters', text: '한글 🧪', relay: true });
  binding.updateSelection(true);
  assert.equal(binding.selected, false);
  assert.equal(binding.consume(action(), now), false);
  binding.confirm(true);
  assert.equal(binding.selected, true);
  assert.equal(binding.consume(action(), now), true);
  assert.equal(binding.consume(action(), now), false, 'A result timeout cannot replay original input');
});

test('source selection and socket changes revoke previous generations', () => {
  const binding = new NativeTerminalBinding(); binding.confirm(true);
  const now = Date.now(), generation = binding.generation;
  const action = { id: 'move', generation, expiresAt: now + 1000, kind: 'left', text: '', relay: true };
  binding.updateSelection(false); binding.updateSelection(true);
  assert.notEqual(binding.generation, generation, 'Switching away and back cannot resurrect a pending frame');
  assert.equal(binding.consume(action, now), false);
  assert.equal(binding.consume({ ...action, id: 'current', generation: binding.generation }, now), true);
  binding.disconnect();
  binding.updateSelection(true);
  assert.equal(binding.selected, false);
  assert.equal(binding.consume({ ...action, id: 'reconnected', generation: binding.generation }, now), false);
});

test('native relay validates expiry, keys and Unicode without inventing a text snapshot', () => {
  const binding = new NativeTerminalBinding(); binding.confirm(true);
  const now = Date.now();
  const action = { id: 'key', generation: binding.generation, expiresAt: now + 1000, kind: 'characters', text: '한글 🧪', relay: true };
  for (const update of [
    { expiresAt: now - 1 }, { expiresAt: now + 6000 }, { generation: 'another original' }, { relay: false },
    { kind: 'submit' }, { kind: 'text' }, { text: 'bad\x03' }, { text: '\n' }, { text: '한'.repeat(3000) },
    { kind: 'left', text: 'hidden input' }, { kind: 'deleteAll', text: '' }
  ]) { assert.equal(binding.consume({ ...action, ...update }, now), false); }
  assert.equal(binding.consume(action, now), true);
  for (const kind of ['enter', 'escape', 'interrupt', 'up', 'down', 'left', 'right', 'backspace', 'delete', 'home', 'end', 'tab']) {
    assert.equal(binding.consume({ ...action, id: kind, kind, text: '' }, now), true);
  }
});
