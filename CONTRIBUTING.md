# Contributing

Thank you for improving this project.

## Before starting

1. Read `README.md` and the relevant product documentation.
2. Run `python3 "../Reports/sync_qa_reports.py"` when working in the Sowens Studios multi-project workspace.
3. Review unresolved tickets for this application, prioritizing blockers.
4. Check the current branch and working tree. Do not overwrite unrelated local changes.

## Development standards

- Keep changes focused and backward compatible.
- Never commit credentials, user data, QA screenshots, local configuration, build output, or DerivedData.
- Add or update regression coverage for behavior changes.
- Use a generic physical-device destination for iOS verification; simulator use is optional.
- Update the changelog and cross-project contract notes when applicable.
- A fixed QA ticket must include a concise “What was fixed” resolution. Only a tester should mark it Verified on device.

## Pull requests

Describe the problem, implementation, validation performed, affected tickets, app/Worker contract impact, and any follow-up device verification. Keep generated files and unrelated formatting out of the change.

## Security

Do not open public issues containing secrets, private user content, screenshots with personal information, or exploitable vulnerability details. Follow `SECURITY.md`.
