# Codex 0.167 owned preservation evidence

The existing owned cross-home probe passed with the installed native 0.167.0 binary on 2026-11-11. It used random private homes and a loopback model, synthetic history and no user credentials or sessions. The committed runner now requires explicit `--probe-0.167`; its default remains 0.166.0.

Command: `AUTOAPPROVE_CODEX_BIN=/absolute/path/to/0.167.0/bin/codex node scripts/codex-cross-home-preservation-check.mjs --probe-0.167 --restore-goal --archive-source --check-settings --check-retirement`.

Observed: the same thread UUID and nonempty history, an independent rollout, the exact Goal row including goal_id and millisecond timestamps, budget 1234 and usage 37 tokens / 19 seconds, unrelated Goal and server retention, independent archived backup verified after process exit, and later-history return to another isolated home. Nondefault reasoning, service tier, base/developer instructions, disabled plugins and runtime workspace roots were checked; inference requests confirmed the corresponding model settings.

This does not prove original-home native return on 0.167, arbitrary running TUI membership, authentication isolation or product session migration. The native return coordinator remains pinned to 0.166 and the runner explicitly rejects combining the 0.167 probe with original-home return.

Separately, `codex-child-goal-transition-check.mjs --expect-rejection` reproduced the official 0.167 refusal of direct `thread/goal/set` pause on a real active V2 child. A loopback model created the parent, child and Goal in a private home. This is an unresolved lifecycle constraint, not an authentication success or a production fix.
