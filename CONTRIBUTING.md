<!-- PROJECT-KNOWLEDGE managed; do not edit this export -->
> Maintained in ProjectKnowledge: `projects/stocked/documents/CONTRIBUTING.md`. This is a generated portable read-only export. Update the central source with `project-knowledge put`; use `project-knowledge publish` to refresh exports. Relative links and code paths below refer to this original project location.

# Contributing

## Before changing code

Read the README and inspect the current branch, working tree and remote updates. Preserve unrelated changes. Identify the owning implementation and affected app, extension, Watch or Worker consumers before editing.

## Development standards

- Keep changes focused and compatible with existing stored data and network contracts.
- Keep credentials, private records, QA captures, local configuration and build output out of Git.
- Add meaningful regression coverage for behavior changes.
- Check changed-file formatting and compile through the shared Stocked scheme.
- Test rendered layouts and relevant empty, loading, offline, cancellation and error states on an available test destination.
- Update user-facing release notes when behavior changes.

Internal QA tickets need a concise description of the fix and actual validation. Device verification is a separate acceptance step.

## Pull requests

Describe the problem, resulting behavior, tests performed, affected consumers and any remaining device checks. Include migration or rollout requirements when a stored-data or service contract changes. Keep generated output and unrelated formatting out of the diff.

## Security reports

Do not publish secrets, private screenshots, user records or vulnerability details in an issue. Follow [SECURITY.md](SECURITY.md).
