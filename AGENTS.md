# Stocked agent instructions

Before planning, editing, building, testing, or reviewing this repository:

1. Run `python3 "../Reports/sync_qa_reports.py"` from the repository root.
2. Read `README-FIRST.md`, `../Reports/AI-INBOX.md`, and `AGENT-HANDOFF.md` completely.
3. Open every relevant unresolved ticket linked from `../Reports/AI-INBOX.md`. Blocker and critical tickets take priority over feature work unless the user explicitly directs otherwise.
4. Read `CROSS-PROJECT-SYNC.md`. If the work affects the Worker or Stocked Mac, read their synchronized copies too.
5. Update `AGENT-HANDOFF.md` with the active plan and ticket numbers before editing code.

## Mandatory new-ticket rule

Any ticket discovered by the report sync is active work. Do not merely mention it or leave it
for a later agent. Before finishing the current coding task:

1. Open every newly discovered ticket and its screenshot/report artifacts.
2. Reproduce or trace the reported behavior in the current code.
3. Implement the smallest complete fix, including shared iOS/Mac/Worker changes when required.
4. Add or update regression coverage and run the appropriate physical-device/generic-device build.
5. Record the ticket number, diagnosis, files changed, and verification result in `AGENT-HANDOFF.md`.
6. Run report sync again in case tickets arrived while the fix was being built, and repeat until no
   newly discovered ticket remains unaudited.

If a ticket is already fixed by current code, verify that with evidence and record that disposition.
If it cannot be safely fixed in scope, document the exact blocker and next action; never silently
skip it. Ticket status may only be closed through QA after device verification—never edit
`ticket.json` to manufacture closure.

After implementing:

1. Update or close affected QA tickets through the app-generated artifacts; never manually falsify ticket status in `ticket.json`.
2. Run `python3 "../Reports/sync_qa_reports.py"` again.
3. Update `AGENT-HANDOFF.md`, `README-FIRST.md`, and every affected `CROSS-PROJECT-SYNC.md` before handing off.
4. Report unresolved blockers explicitly. Do not claim completion while a relevant open blocker remains unexplained.

These instructions apply to Codex, ChatGPT, Claude, and any other coding agent operating in this checkout.
