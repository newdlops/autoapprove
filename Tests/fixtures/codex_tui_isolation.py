"""Fail closed if the production controller appears during an owned TUI probe."""
import os
import pathlib
import signal
import subprocess
import threading


def require_no_production_controller():
    processes = subprocess.run(
        ['/bin/ps', '-axo', 'comm='], check=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, timeout=3).stdout.splitlines()
    if any(pathlib.Path(value.strip()).name == 'AutoApproveApp' for value in processes):
        raise RuntimeError('Quit AutoApprove before this opt-in native probe: '
                           'two independent transition controllers must not operate '
                           'the same temporary server')


class IsolationGuard:
    def __init__(self, inspect=require_no_production_controller, interval=.25):
        self.inspect = inspect
        self.interval = interval
        self.stopped = threading.Event()
        self.error = None
        self.worker = None

    def start(self):
        self.inspect()
        self.previous = signal.signal(signal.SIGUSR1, self._abort)
        self.worker = threading.Thread(target=self._watch, daemon=True)
        self.worker.start()

    def _abort(self, *_):
        raise RuntimeError('Owned TUI probe isolation lost; stopping only fixture resources') from self.error

    def _watch(self):
        while not self.stopped.wait(self.interval):
            try:
                self.inspect()
            except Exception as error:
                self.error = error
                os.kill(os.getpid(), signal.SIGUSR1)
                return

    def stop(self):
        # Block a pending guard signal while joining, then consume it before
        # restoring the caller's handler. Cleanup must never be interrupted.
        if self.worker is None:
            return
        old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1})
        try:
            self.stopped.set()
            self.worker.join()
            if signal.SIGUSR1 in signal.sigpending():
                signal.sigwait({signal.SIGUSR1})
            signal.signal(signal.SIGUSR1, self.previous)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
