// Called with a production engine and isolated PTY; never writes to user terminals.
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const screen = command => 'Would you like to run the following command?\n\nEnvironment: local\n\n$ ' + command
  + "\n\n› 1. Yes, proceed (y)\n  2. Yes, and don't ask again for commands that start with `" + command
  + '` (p)\n  3. No, and tell Codex what to do differently (esc)\n\nPress enter to confirm or esc to cancel';

export async function runApprovalRace({ bridge, fixtures, sessions, actions, retryOnly = false }) {
  const fixture = fixtures[0], session = sessions[0];
  const show = value => bridge.request('screen', { terminalID: fixture.id, screen: value, generation: 'rapid-same-process' });
  const until = async (check, label) => {
    const deadline = Date.now() + 12000;
    while (Date.now() < deadline) { if (await check()) return; await sleep(10); }
    throw Error('Timed out: ' + label);
  };
  await bridge.request('register', { terminals: fixtures });
  await bridge.request('automatic', { sessionID: session.id, enabled: true });
  bridge.unacknowledged.add(fixture.id);
  let waiting;
  let failure;
  const acknowledgements = [];
  bridge.onApproval = action => {
    try {
      assert.ok(waiting, 'No duplicate input between requests');
      assert.equal(action.terminalID, fixture.id);
      assert.equal(action.dialog, waiting.screen);
      assert.equal(action.answer, '1');
      const accepted = waiting;
      waiting = undefined;
      // The next request may appear before the preceding delivery callback returns.
      const acknowledgement = sleep(accepted.ackDelay).then(() => bridge.request('actionResult', {
        actionID: action.id, success: accepted.success
      })).catch(error => { failure = error; });
      acknowledgements.push(acknowledgement);
      accepted.resolve(action);
    } catch (error) { failure = error; waiting?.reject(error); waiting = undefined; }
  };
  const approve = async (value, ackDelay = 750, success = true) => {
    if (failure) throw failure;
    let timer;
    const delivered = new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(Error('No rapid approval: ' + value.split('\n')[4])), 12000);
      waiting = { screen: value, resolve, reject, ackDelay, success };
    });
    try { await Promise.all([show(value), delivered]); }
    finally { clearTimeout(timer); }
  };
  try {
    if (!retryOnly) {
    for (const gap of [0, 1, 5, 10, 25, 50]) {
      const before = actions.length, started = performance.now();
      for (let index = 0; index < 10; index++) {
        if (gap) await sleep(gap);
        await approve(screen(`printf 'gap-${gap}-${index}'`), index % 2 ? 250 : 1500, index % 4 !== 0);
      }
      await Promise.all(acknowledgements);
      if (failure) throw failure;
      assert.equal(actions.length - before, 10);
      console.log(JSON.stringify({ stage: 'rapid-next-request', gapMilliseconds: gap,
        acknowledgements: '250/1500ms, including old failures', approvals: 10,
        seconds: Math.round((performance.now() - started) / 100) / 10 }));
    }

    // A redraw can remove one footer line while delivery is still pending.
    const redraw = screen('printf redraw-after-dispatch');
    await approve(redraw, 1500);
    const beforeRedraw = actions.length;
    await show(redraw.replace('Press enter to confirm or esc to cancel', ''));
    await show(redraw);
    await sleep(1800);
    if (failure) throw failure;
    assert.equal(actions.length, beforeRedraw, 'An incomplete redraw must not replay an in-flight input');
    console.log('PASS incomplete redraw retains single-use approval');
    await show('Working (esc to interrupt)');
    await approve(redraw, 250);
    assert.equal(actions.length, beforeRedraw + 1, 'An observed work transition permits a genuinely new identical request');

    // No active dialog: neither toggling approval nor resuming may use a retained old frame.
    await show(redraw.replace('Press enter to confirm or esc to cancel', ''));
    await bridge.request('automatic', { sessionID: session.id, enabled: false });
    await bridge.request('automatic', { sessionID: session.id, enabled: true });
    await bridge.request('pause', { paused: true });
    await bridge.request('pause', { paused: false });
    await sleep(500);
    assert.equal(actions.length, beforeRedraw + 1, 'An incomplete frame cannot dispatch on enable/resume');
    await show(redraw);
    await Promise.all(acknowledgements);
    }

    // Four definitive non-writes during a redraw must recover after the screen settles.
    // This is independent of missing/uncertain receipts, which must never be resent.
    const unstable = screen('printf changed-request-after-redraw');
    let attempts = 0, accepted = 0;
    const attemptTimes = [];
    bridge.onApproval = action => {
      try {
        assert.equal(action.dialog, unstable);
        assert.equal(action.answer, '1');
        attemptTimes.push(performance.now());
        const success = ++attempts > 4;
        if (success) accepted++;
        acknowledgements.push(bridge.request('actionResult', { actionID: action.id, success }).catch(error => { failure = error; }));
      } catch (error) { failure = error; }
    };
    await until(async () => {
      if (failure) throw failure;
      await show(unstable);
      return accepted === 1;
    }, 'four unsent inputs recover when the new command stops redrawing');
    for (let index = 0; index < 10; index++) { await show(unstable); await sleep(10); }
    assert.equal(attempts, 5); assert.equal(accepted, 1);
    for (let index = 1; index < attemptTimes.length; index++) {
      assert.ok(attemptTimes[index] - attemptTimes[index - 1] >= 250 * 2 ** (index - 1) - 10,
        'Confirmed non-writes must back off instead of flooding the terminal');
    }
    console.log('PASS four confirmed non-writes recover with one delivered input');

    await show('Working (esc to interrupt)');
    await Promise.all(acknowledgements);
    await until(async () => (await bridge.request('status')).events.every(event => event.outcome !== '승인 시도 · 결과 미확인'), 'all delayed receipts');
    if (failure) throw failure;
    console.log(retryOnly ? 'PASS confirmed-unsent recovery with backoff'
      : 'PASS rapid approvals, delayed and out-of-order callbacks, transient redraw');
  } finally {
    bridge.onApproval = undefined;
    bridge.unacknowledged.clear();
    await Promise.all(acknowledgements);
  }
}
