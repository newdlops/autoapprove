# Remote Codex diagnostics implementation plan

**User choice:** A dedicated diagnostic Codex on the remote Mac; existing conversations and Goals continue.

**Architecture:** The target AutoApprove collects an allowlisted read-only snapshot, including actual managed-server witnesses and current versus historical attachment records. A separate ephemeral Codex analyzes that snapshot using saved local login, with external tools disabled. Existing node identity routing and Origin checks carry requests/results; no SSH, input injection or auth-file export. A request ID identifies one bounded diagnosis; retries only observe its status.

**Design contract:** Add a compact diagnostic dialog from each Mac row. Show machine/timestamp, summary and current blockers before the AI analysis. Keep operational lists and historical records in collapsed details, with header and footer controls visible while the body scrolls. Reuse system fonts and existing CSS tokens, 44px controls, accessible dialog names/focus/Escape; 390/768/1440 layouts and light/dark. Loading, unsupported/offline, partial data, failure, cancellation, long text, export and stale node responses need separate functional and visual QA. No repair action or automatic session changes.

- [x] Implement and test snapshot collection, redaction and live/historical classification; clear only stale UI notices, retain the journal.
- [x] Implement isolated Codex request lifecycle, deduplication, structured results, bounded failure/cancellation and live service proof.
- [x] Implement per-Mac UI with explicit diagnosis, progress, result/evidence, refresh and export; real browser QA.
- [x] Integrate HTTP/CLI collection, verify Origin and exact node identity, active-diagnosis update/stop behavior.
- [ ] Run relevant checks and source/UI review; release 0.2.249/build276 with signed assets and checksums, install/verify locally and test target-Mac diagnostics.

Independent runner and UI files follow .runtime/diagnostics-249/contract.md during implementation. They do not edit the shared engine, routing or registry.

Release/installation evidence is recorded separately in VALIDATION.md after publication.
