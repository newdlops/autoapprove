# Goal native transport correction

The actual Terminal escape adapter requires a frozen sourceIdentity. 0.2.246 supplied only PID/start/TTY; its fixture bypassed that guard. A real TerminalDeviceInput guard + actual owned-process identity capture + injected owned-PTY sink reproduced the rejection.

Freeze identity once for the needsPause action and pass it through the live adapter. Keep PID/start, UID/device/foreground checks intact. Record confirmed absent pause delivery separately; only a new explicit reconnect discards such unstarted plans and rediscovers the current thread/Goal. Recognize the exact 0.2.246 false-return detail as known non-delivery; never rearm unknown exceptions, partial writes or already observed pauses. Check direct-input availability before dispatch and give the existing connection guidance.

All Goal Esc fixtures now exercise the actual TerminalDeviceInput guards and kernel metadata. Only the final sink is replaced with the owned PTY writer. This does not claim actual XPC/helper/TIOCSTI or real user Terminal verification. Preserve other work and finish 0.2.247/build274 source, signed packages, GitHub publication, install and process checks. No new UI layout.

## Helper-absent Mac recovery

The explicit reconnect Goal pause uses TerminalGoalInterrupt: direct service when already available, otherwise existing accessibility event posting. It does not register/install a privileged service. No cross-transport replay follows an attempted input. Keyboard preparation keeps the original exact-window and foreground-owner checks, adds frozen kernel identity and immediate user-input-priority validation, and normalizes only the busy footer spinner/timer. No permission means a macOS request plus known-not-started state; a new explicit click re-discovers the current Goal. Unknown keyboard outcomes remain manual review, even when another transport becomes available.
