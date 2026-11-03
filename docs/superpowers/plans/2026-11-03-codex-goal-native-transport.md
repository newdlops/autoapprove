# Goal native transport correction plan

1. Reproduce missing frozen identity using real TerminalDeviceInput guards (transport-red.log) and retry-marker loss (retry-red.log).
2. Bind the original kernel identity, preflight availability, persist known non-delivery and allow explicit rediscovery including legacy confirmed false delivery.
3. Route every Goal Esc fixture through real guards, actual kernel capture and owned sink. Verify happy, missing-input retry, unknown ack, cancellation, manager replacement and account continuation in Debug/Release; one final focused source review.
4. Publish matching 0.2.247/build274 DMG/signed ZIP/checksums, publicly verify, install and verify original process preservation.

Review: review_native_goal_transport_247 reported no Critical/Important findings. This was source/log review only. Native service availability and real Terminal behavior remain unverified. The prior release was moved to prerelease with a known-issue note; stable latest was restored to 0.2.245 until this correction passes.

User follow-up: direct input service is unavailable on the affected Mac. Add an explicit-Goal-only accessibility keyboard fallback, without installing a service. Prefer direct input; never change transport after any attempted submission. Revalidate frozen kernel identity, original window/TTY and focus, and user input priority before posting. Only spinner/time changes may normalize. Missing permissions request macOS consent and remain known-not-started. Test actual generated script, helper-absent success, focus-change rejection and unknown key acknowledgement without replay. Focused review review_goal_keyboard_247 found no Critical/Important issues (source and exact JS normalization execution only).
