import argparse
import os
import selectors
import signal
import subprocess
import sys
import time


def run(command, case_seconds, total_seconds):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    finished = False
    started = last_case = time.monotonic()
    latest = "startup"
    pending = b""

    def interrupt(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                now = time.monotonic()
                if now - started >= total_seconds or now - last_case >= case_seconds:
                    print(f"FAIL watchdog timeout ({latest})", file=sys.stderr, flush=True)
                    return 124
                if not selector.select(timeout=0.2):
                    continue
                part = os.read(process.stdout.fileno(), 65536)
                if not part:
                    remaining = min(total_seconds - (now-started), case_seconds - (now-last_case))
                    try:
                        status = process.wait(timeout=max(0, remaining))
                        finished = True
                        return status
                    except subprocess.TimeoutExpired:
                        print(f"FAIL watchdog timeout ({latest})", file=sys.stderr, flush=True)
                        return 124
                sys.stdout.buffer.write(part)
                sys.stdout.buffer.flush()
                lines = (pending + part).split(b"\n")
                pending = lines.pop()[-4096:]
                for line in lines:
                    if line.startswith(b"CHECK "):
                        latest = line[6:512].decode(errors="replace")
                        last_case = time.monotonic()
    except KeyboardInterrupt:
        return 130
    finally:
        if not finished:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=0.3)
                except subprocess.TimeoutExpired:
                    pass
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait()
        process.stdout.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--case-seconds", type=float, default=120)
    parser.add_argument("--total-seconds", type=float, default=1800)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or min(args.case_seconds, args.total_seconds) <= 0:
        parser.error("Supply positive deadlines and the check executable")
    sys.exit(run(command, args.case_seconds, args.total_seconds))
