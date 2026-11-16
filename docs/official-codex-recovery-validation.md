# Official Codex recovery validation

The acceptance scope is [the November 17 agreement](superpowers/specs/2026-11-17-official-codex-recovery.md).
This change uses the original signed OpenAI Codex 0.169.0 package. It does not
restore the retired private TUI attachment protocol or connection census.

## Functional evidence

- Debug regression suite: 305/305 passed with the public move and automatic
  standalone-enrollment entry points enabled.
- Final production build: 0.2.314 build 341, successful; the matching release
  executable passed all 276 regression checks after the automatic-proposal fix.
- `scripts/codex-official-cohort-check.mjs --runtime=<official-package>` runs two
  real official TUIs in isolated PTYs. Only the desktop screen adapter is fake;
  user terminals and credentials are not used. `--lose-launch-reply` recreates
  the app controller and observes restoration without another launch.
- `--standalone-cohort --same-home --automatic-enrollment` verifies the actual
  automatic dispatcher, preserving the managed neighbor and daemon.
  Adding `--automatic-before-effects` recreates the controller before any exit:
  a manual proposal stays pending, while an abandoned automatic proposal is
  discarded and prepared again from current state without duplicate effects.
  The combined `--automatic-before-effects --lose-launch-reply` run passed
  against the final recovery implementation: one affected client, one launch,
  no turn replay, and unchanged neighbor, group roles, inbox and acknowledgements.
- `--standalone-cohort --same-home --background-tool` runs an actual background
  tool, observes its exit, and preserves an unrelated sibling shell command.
- `--dedicated-split --paused-goals` verifies the registered dedicated home,
  original server, cold account name and exact paused Goal state.
- `--late-child --roundtrip` creates a child after preparation and a newer turn
  after the first move. The return preserves the latest root and child history,
  including the separate paginated history index. The other home is not restarted.
- `--active-root-goals` verifies two active root Goals, retained identities,
  budgets and charged usage, and one continuation per restored Goal.
- `--unsupported-history-schema` verifies that incompatible stored history is
  refused before any client exit, launch, group edit or acknowledgement change.
- `--late-child --active-child-goal` verifies a real active child Goal, native
  quiescence, cold loading and one continuation of the original Goal.
- Adding `--recover-moved-intent` to the active-child dedicated split verifies
  reconciliation of an unresolved request from the original home. The
  `--superseded-moved-intent` scenario preserves a newer confirmed destination
  request. Only journal-proven homes participate in request ordering.
- All cohort scenarios verify current Session UUIDs, original PTYs, selected-only
  home changes, group/member/leader/parent identities, pending mailbox entries,
  prior acknowledgements, automatic approval settings and no command replay.
- `scripts/codex-thread-history-recovery-check.mjs --seed-home=<owned-cohort-home>`
  clones synthetic official history. Keep a seed with the cohort check's
  `--late-child --keep`, then use its printed root plus `/home`. Live database
  owners retain the production WAL mode during the test. Actual helper process death before commit
  rolls back; death after commit is observed without another replacement. Changed
  source, changed destination, unknown schema and unowned replacement are rejected.
  An authorized retired return changes only the selected thread's index rows.
- `scripts/codex-child-goal-transition-check.mjs` verifies controller death at four
  pause checkpoints and three resume checkpoints. Recovery retains the exact Goal,
  budget and monotonic accounting, adds no parent message, does not charge paused
  time, and does not blindly dispatch the uncertain request again.
- `scripts/codex-cross-home-preservation-check.mjs --probe-0.169 --restore-goal
  --check-retirement --archive-source --return-original-home --official-retirement
  --publication-ack-loss --storage-publication-only` kills its helper after the
  latest archive rename. Cold recovery confirms exactly one publication and
  preserves the latest exact Goal and unrelated Goal.
- Conversation-based MCP identity tests retain the unrelated observed process,
  reject mismatched conversation/home evidence and preserve a uniquely matched
  live parent's existing Claude task authority. Claude implementation is unchanged.

## Native UI evidence

The existing system fonts, semantic colors, standard controls and 24-point
padding are retained. Account panels were rendered at 350 and 600 points in
light and dark appearances across eight states, including loading, error,
disabled and long text. The 600×660 split sheet and shared progress components
were inspected separately; the latter include dense counts, pending, failure,
success and long paths in both appearances.

Normal interactions in the separate synthetic preview app verified opening the
move sheet, picking a destination, refusing an unobserved session, Escape to
close, blank-name disabling, creating a private test home, long-name/path
wrapping and scrolling the split sheet. No browser login or real terminal action
was performed in that preview. Full native keyboard navigation outside Escape
was not established. Browser/mobile viewport checks do not apply to these native
macOS sheets. Packaged release and running-version checks are recorded separately
when the matching release is deployed.
