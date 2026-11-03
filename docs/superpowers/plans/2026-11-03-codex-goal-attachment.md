# Goal attachment fix plan

1. Reproduce explicit reconnect of a running Goal using a real owned PTY; preserve automatic wait coverage.
2. Add persisted pause reservation and read-only completion barrier, exact busy status binding, and account coordinator adoption of the previously stopped Goal.
3. Cover ambiguous pause, changed Goal/turn, draft/question and original paused Goal; run relevant Debug/Release checks and source review.
4. Release 0.2.246/build273 with matching signed artifacts, public verification, local installation and original process preservation.

## Execution ledger

- Owned direct CLI with active Goal reproduced the original no-interrupt/no-attachment failure. A separate coordinator test reproduced missing adoption of a previously paused Goal (0/1), then passed.
- Pausing updates the real synthetic Goal database before connection. The fixture was corrected to redraw stale Working text and later to place the lifecycle footer after the composer, matching the CLI.
- Preserve generic paused-Goal automation policy: its ActivityDetector state remains unknown. Only the explicit attachment path uses Goal-aware readiness and the observed exact paused Goal; do not globally relax automatic recovery.
- A delayed pause result after request cancellation reproduced an unintended automatic exit. Revoke unused pre-exit Goal plans to review; a new explicit retry may reuse a confirmed paused Goal when no exit was reserved.
- One independent final source review reported three Important findings: paused footer in prepare, stale status proof in same-shell exit, and partial/native-fallback account rotation after attachment failure. All were reproduced and fixed. The reviewer did not operate user sessions; its one detector micro-check exited 137 and is not test evidence.
- An additional owned-PTY regression reproduced an in-flight browser request surviving account-manager replacement. Own and cancel that task, clear only its pending guard, and fence completion/failure by manager identity and epoch.
- Smoke checks passed for manager replacement, successful browser handoff, idle active Goal, originally paused Goal, and cancellation followed by explicit retry. Final Debug/Release verification and release/install evidence follow.

- A closed original process left a stale Goal review blocking a fresh explicit managed reconnect. Reproduced in a private overlay while release compilation was frozen, then restricted the review barrier to its live original process; persisted browser failure still requires a successful explicit reconnect. The final 45-step sweep includes restoration and closed-original recovery.
- One candidate pair was invalidated because its fixture file changed during swiftc. Those results were archived and excluded; the fixed source/test sweep was rerun completely and passed all 45 steps.
- A separate owned-PTY probe reproduced input sent into Vim Normal mode. Add Goal-specific working readiness rejecting Normal/Replace modes; preserve generic progress and paused-Goal inference. Final Debug/Release builds and related Goal/attachment/Vim/normal/native/failure checks are rerun after that last guard.

- A delayed status response plus subsequent Working repaint reproduced a 10-second proof-age rejection. Align the Goal pause card lease with the existing 120-second pause reservation, retaining exact process/home/thread/Goal and single-use input checks. Add an 11-second owned status fixture; repeat final builds and related checks including that case (16 steps). No further code or test edits during the final run.
