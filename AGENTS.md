## User-visible UI and frontend work

- Use `$ui-design-workflow` before changing a user-visible interface, except a pure copy edit that cannot affect layout.
- Read applicable instructions and inspect the existing design system and adjacent screens. Preserve existing components, tokens and visual language.
- For substantial UI work, establish the design direction and acceptance checks before implementation.
- Cover relevant loading, empty, error, success, disabled, focus, hover, selected, long-text and overflow states.
- Verify function and appearance separately. Inspect real mobile, tablet and desktop rendering when browser tooling is available. Claim only checks actually performed.
- Use the smallest useful specialist set: UI UX Pro Max for new direction, Impeccable for critique, Web Design Guidelines for accessibility, and React best practices only for React/Next.js.

## Version changes and GitHub releases

- User instruction, 2026-10-05: when a version is increased, finish the GitHub release deployment as part of the task. Do not finish after only a local build or installation.
- Run the relevant checks, package the matching version, commit the release source, push its tag and publish the GitHub release with the install artifact and checksum.
- Verify the published tag, assets and download. If deployment is blocked, report the precise blocker and which deployment step remains.
- Preserve unrelated workspace changes. Never publish local runtime data, signing secrets, keychains, user terminal content or private test artifacts.
