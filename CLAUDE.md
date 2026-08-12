# Claude project instructions

Follow `AGENTS.md` as the authoritative workflow. At the beginning of every session, resume, or compaction, run:

```bash
python3 "../Reports/sync_qa_reports.py"
```

Then read `README-FIRST.md`, `../Reports/AI-INBOX.md`, `AGENT-HANDOFF.md`, and `CROSS-PROJECT-SYNC.md` before proposing or applying changes. Follow the mandatory new-ticket rule in `AGENTS.md`: every newly discovered ticket must be audited and fixed during the active work cycle, then synced again before handoff. QA blockers have priority and ticket numbers must appear in the handoff plan and final summary.
