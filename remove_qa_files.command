#!/bin/bash
# Deletes the retired QA Workbook code from the Stocked repo.
# Run from anywhere: double-click in Finder, or `bash remove_qa_files.command`.
# Safe to run twice. Xcode synchronized folders pick up the removals automatically.
cd "$(dirname "$0")"
# If this script sits inside the delta folder, target the repo root that contains Stocked/.
for ROOT in . .. "$HOME/Documents/Stocked 2"; do
  if [ -f "$ROOT/Stocked/StockedApp.swift" ]; then cd "$ROOT"; break; fi
done
echo "Repo: $(pwd)"
for f in QAChangeLog.swift QAFeedback.swift QAFloatingOverlay.swift QAWorkbook.swift \
         QAWorkbookTheme.swift QAWorkbookViews.swift QAWorkbookContent.json; do
  if [ -f "Stocked/$f" ]; then rm "Stocked/$f" && echo "deleted Stocked/$f"; else echo "already gone: Stocked/$f"; fi
done
echo "Done. Rebuild in Xcode."
