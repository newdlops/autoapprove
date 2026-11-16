# Official Codex feature recovery

The user's November 17 agreement supersedes the full retained-input and
uninterrupted-client conditions in the November 16 investigation. This is the
acceptance scope, not a completion claim.

1. Hidden unsent drafts are not required. Preserve persisted conversations,
   session IDs, work folders, login homes and collaboration-group relationships.
   A readable draft may be saved locally, but hidden-input export must not block
   migration, split or existing-session enrollment.
2. Restarting the affected server's sessions together is authorized. Capture
   their restoration records before stopping them, confirm their exit, restart
   the official server, restore each conversation and verify group rebinding.
   Running commands may be interrupted. Do not equate restored history with
   successful continuation of a command. Preserve unrelated Claude behavior.
   The user explicitly chose: only the selected terminal moves to the destination
   login group; other affected terminals reopen in their original login group.
3. Use the terminal's `/status` Session ID for session discovery and refresh.
   A private server connection-ID census is not a prerequisite. Restore account
   and server observation without pretending to provide that internal census.
4. Keep the verified child-approval navigation returning Main. Arbitrary prior
   child-view restoration is deferred, not a gate for this recovery.
5. Persist each Goal intent before effects. Reconcile the same Goal instance
   against the desired lifecycle state after restart. Confirm an already met
   intent without retransmission; use fresh state for remaining work. Changed
   Goal instances, newer superseding intents and uncertain native execution
   require explicit handling rather than blind replay. Old receipts without
   target metadata cannot authorize inferred requests.

Verification must cover original signed Codex, actual restart and cold history
restoration, multiple affected sessions, preserved group roles and message
bindings, `/status` identity refresh, Goal controller death before/after effects,
superseded/replaced Goals and old journals. Synthetic unit tests alone are not
evidence of the complete workflow. Finish with the matching app build, source
commit/tag, GitHub DMG and update ZIP plus checksums, download verification,
local installation and running-version verification.
