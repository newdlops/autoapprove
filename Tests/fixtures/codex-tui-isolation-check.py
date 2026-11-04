#!/usr/bin/env python3
"""Exercise late controller arrival and lookup failure in disposable processes."""
import pathlib
import signal
import subprocess
import sys
import time
import unittest
from unittest import mock
from codex_tui_isolation import IsolationGuard, require_no_production_controller


def child(scenario):
    calls = 0
    def inspect():
        nonlocal calls
        calls += 1
        if calls > 1:
            if scenario == 'lookup-failure':
                raise subprocess.TimeoutExpired('ps', 3)
            raise RuntimeError('production controller appeared')
    original = signal.getsignal(signal.SIGUSR1)
    guard = IsolationGuard(inspect=inspect, interval=.01)
    aborted = False
    try:
        guard.start()
        time.sleep(2)
    except RuntimeError as error:
        assert 'isolation lost' in str(error)
        assert isinstance(error.__cause__, subprocess.TimeoutExpired if scenario == 'lookup-failure' else RuntimeError)
        aborted = True
    finally:
        guard.stop()
    assert aborted and not guard.worker.is_alive()
    assert signal.getsignal(signal.SIGUSR1) == original
    # A delayed signal must not interrupt cleanup or terminate the process.
    time.sleep(.05)
    print('aborted-and-cleaned')


class Checks(unittest.TestCase):
    def test_startup_refuses_exact_app_process(self):
        with mock.patch('codex_tui_isolation.subprocess.run', return_value=mock.Mock(stdout='/Applications/AutoApprove.app/Contents/MacOS/AutoApproveApp\n')):
            with self.assertRaisesRegex(RuntimeError, 'Quit AutoApprove'):
                require_no_production_controller()

    def test_noncontroller_names_do_not_match(self):
        with mock.patch('codex_tui_isolation.subprocess.run', return_value=mock.Mock(stdout='/tmp/AutoApproveApp-test\n/tmp/AutoApproveCLI\n')):
            require_no_production_controller()

    def test_startup_lookup_failure_is_not_accepted(self):
        with mock.patch('codex_tui_isolation.subprocess.run', side_effect=subprocess.TimeoutExpired('ps', 3)):
            with self.assertRaises(subprocess.TimeoutExpired):
                require_no_production_controller()

    def test_late_controller_aborts_blocked_main_and_disarms_cleanup(self):
        self.run_child('late-controller')

    def test_late_lookup_failure_also_aborts(self):
        self.run_child('lookup-failure')

    def run_child(self, scenario):
        result = subprocess.run([sys.executable, str(pathlib.Path(__file__).resolve()), '--child', scenario],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'aborted-and-cleaned')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--child':
        child(sys.argv[2])
    else:
        unittest.main()
