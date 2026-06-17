Branch name: fix/buildconfig-worker-auth

This delivery is in repo-relative format: the folder mirrors your repo, so
Stocked/BuildConfig.swift lands exactly where it belongs.

In stocked.command:
  5) New branch        -> name it: fix/buildconfig-worker-auth  (base: main)
  2) Apply Claude delivery   -> pick this zip; it overlays Stocked/BuildConfig.swift,
                                then commits with COMMIT_MSG.txt and pushes the branch
  8) Open in Xcode     -> Clean Build Folder (Shift-Cmd-K), build -> 5 errors gone
  6) Merge a branch    -> merge fix/buildconfig-worker-auth into main when happy

(If you haven't done the one-time repo setup yet, do that first per
README_WORKFLOW.md, then run the steps above.)
