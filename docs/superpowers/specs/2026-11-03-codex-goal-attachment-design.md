# Explicit Goal pause before standalone attachment

The user reports that an active Goal keeps working and never reaches managed-server attachment. The previous wait-only policy is correct for background discovery, but contradicts the already requested explicit pause → connect → same-work continuation flow.

Use the original verified CLI: fresh /status is supported during a running turn in official 0.166.0; verify the exact home and Goal, persist a pause reservation, send one Esc for an empty working composer (which pauses the Goal), or /goal pause at an empty idle composer. Observe the same Goal becoming paused and an idle original frame before replacement preparation and graceful exit. Never clear a Goal or write its database. Missing or changed evidence, questions and drafts wait; uncertain input is never repeated. Automatic discovery remains wait-only.

Capture the exact paused managed turn after attachment, and pass the stopped Goal into the existing account coordinator only for the matching login request. Its normal durable server/reconnection/continuation reservations resume that Goal after the new account is verified, preserving original pauses and rejecting changed Goal/turn identity. Browser-login completion should run the same authorized standalone attachment path once before account switching.

Test against owned PTYs and a synthetic server. Do not operate real user Terminal sessions as QA. Finish build, signed packages, public release and installation/version/process checks. No new UI layout.
