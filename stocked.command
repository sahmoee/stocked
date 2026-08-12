#!/bin/bash
# ============================================================================
# Stocked Dev Console — one-stop git + Xcode workflow for the Stocked app.
# Double-click this file in Finder (after `chmod +x stocked.command` once).
# It finds its own folder as the repo root, so it works wherever you put it —
# as long as it sits at the top of the Stocked git repo.
# ============================================================================

set -u

# Repo root = the folder this script lives in.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO" || { echo "Can't cd to repo at $REPO"; exit 1; }

# Where you drop automated delivery archives (default: ~/Downloads).
DELIVERY_DIR="${STOCKED_DELIVERY_DIR:-$HOME/Downloads}"

BOLD="\033[1m"; DIM="\033[2m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; RESET="\033[0m"

pause() { echo; read -r -p "Press Return to continue… " _; }

require_git() {
  if [ ! -d "$REPO/.git" ]; then
    echo -e "${RED}This folder is not a git repo yet.${RESET}"
    echo "Run the first-time setup in README_WORKFLOW.md, then come back."
    pause; exit 1
  fi
}

current_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null; }

dirty_check() {
  # Returns 0 if there are uncommitted changes.
  ! git diff-index --quiet HEAD -- 2>/dev/null
}

open_xcode() {
  local proj
  proj="$(find "$REPO" -maxdepth 2 -name '*.xcworkspace' | head -n1)"
  [ -z "$proj" ] && proj="$(find "$REPO" -maxdepth 2 -name '*.xcodeproj' | head -n1)"
  if [ -z "$proj" ]; then
    echo -e "${RED}No .xcodeproj or .xcworkspace found under $REPO.${RESET}"; return
  fi
  echo -e "${GREEN}Opening $(basename "$proj")…${RESET}"
  open "$proj"
}

pull_current() {
  local b; b="$(current_branch)"
  echo -e "${CYAN}Pulling latest on ${BOLD}$b${RESET}${CYAN}…${RESET}"
  git pull --ff-only origin "$b" || {
    echo -e "${YELLOW}Fast-forward failed (history diverged). Trying a merge pull…${RESET}"
    git pull --no-edit origin "$b"
  }
}

list_branches() {
  echo -e "${BOLD}Local branches:${RESET}"
  git branch
  echo -e "\n${BOLD}Remote branches:${RESET}"
  git branch -r
}

switch_branch() {
  echo -e "${BOLD}Available branches:${RESET}"
  git branch -a | sed 's/remotes\/origin\///' | sort -u | grep -v 'HEAD'
  echo
  read -r -p "Branch to switch to: " target
  [ -z "$target" ] && return
  if dirty_check; then
    echo -e "${YELLOW}You have uncommitted changes.${RESET}"
    read -r -p "Stash them before switching? [y/N] " ans
    [ "$ans" = "y" ] && git stash push -m "auto-stash before switch $(date +%H:%M)"
  fi
  if git show-ref --verify --quiet "refs/heads/$target"; then
    git checkout "$target"
  else
    # Track a remote branch of the same name if it exists.
    git checkout -t "origin/$target" 2>/dev/null || git checkout "$target"
  fi
  git pull --ff-only origin "$target" 2>/dev/null || true
}

new_branch() {
  read -r -p "New branch name (e.g. feature/widgets): " name
  [ -z "$name" ] && return
  read -r -p "Branch from which base? [main] " base
  base="${base:-main}"
  git checkout "$base" && git pull --ff-only origin "$base" 2>/dev/null
  git checkout -b "$name"
  echo -e "${GREEN}Created and switched to $name.${RESET}"
  read -r -p "Push it to GitHub now? [Y/n] " ans
  [ "$ans" != "n" ] && git push -u origin "$name"
}

merge_branch() {
  local cur; cur="$(current_branch)"
  echo -e "Current branch: ${BOLD}$cur${RESET}"
  git branch
  echo
  read -r -p "Merge WHICH branch INTO $cur? " src
  [ -z "$src" ] && return
  git fetch origin "$src" 2>/dev/null
  if git merge --no-edit "$src"; then
    echo -e "${GREEN}Merged $src into $cur.${RESET}"
    read -r -p "Push $cur to GitHub now? [Y/n] " ans
    [ "$ans" != "n" ] && git push origin "$cur"
  else
    echo -e "${RED}Merge hit conflicts. Resolve them in Xcode/editor, then commit.${RESET}"
  fi
}

commit_push() {
  if ! dirty_check && [ -z "$(git status --porcelain)" ]; then
    echo -e "${DIM}Nothing to commit.${RESET}"; return
  fi
  git status --short
  echo
  read -r -p "Commit message: " msg
  [ -z "$msg" ] && { echo "Aborted (empty message)."; return; }
  git add -A
  git commit -m "$msg"
  local b; b="$(current_branch)"
  git push origin "$b"
  echo -e "${GREEN}Pushed to origin/$b.${RESET}"
}

apply_delivery() {
  # Find the newest Stocked delivery zip in the delivery dir.
  local zip
  zip="$(ls -t "$DELIVERY_DIR"/Stocked*.zip 2>/dev/null | head -n1)"
  if [ -z "$zip" ]; then
    echo -e "${YELLOW}No Stocked*.zip found in $DELIVERY_DIR.${RESET}"
    read -r -p "Full path to the delivery zip: " zip
  else
    echo -e "Newest delivery: ${BOLD}$(basename "$zip")${RESET}"
    read -r -p "Use this one? [Y/n] (n = type a path) " ans
    if [ "$ans" = "n" ]; then read -r -p "Full path to the delivery zip: " zip; fi
  fi
  [ ! -f "$zip" ] && { echo -e "${RED}Not a file: $zip${RESET}"; return; }

  local tmp; tmp="$(mktemp -d)"
  unzip -q "$zip" -d "$tmp"
  # The zip contains ONE top folder; its contents are repo-root-relative.
  local inner; inner="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [ -z "$inner" ] && inner="$tmp"

  echo -e "${CYAN}Files in this delivery:${RESET}"
  (cd "$inner" && find . -type f -not -name 'COMMIT_MSG.txt' | sed 's|^\./|  |')
  echo
  read -r -p "Overlay these into the repo? [y/N] " ans
  [ "$ans" != "y" ] && { rm -rf "$tmp"; echo "Aborted."; return; }

  # Copy everything except the commit-message helper, preserving paths.
  rsync -a --exclude 'COMMIT_MSG.txt' "$inner"/ "$REPO"/

  echo -e "${GREEN}Applied.${RESET} git status:"
  git status --short

  # Use the bundled commit message if present.
  local msg=""
  [ -f "$inner/COMMIT_MSG.txt" ] && msg="$(cat "$inner/COMMIT_MSG.txt")"
  rm -rf "$tmp"

  echo
  read -r -p "Commit & push now? [Y/n] " ans
  if [ "$ans" != "n" ]; then
    [ -z "$msg" ] && read -r -p "Commit message: " msg
    [ -z "$msg" ] && { echo "Aborted (empty message)."; return; }
    git add -A
    git commit -m "$msg"
    local b; b="$(current_branch)"
    git push origin "$b"
    echo -e "${GREEN}Pushed to origin/$b.${RESET}"
  fi
}

status_view() {
  echo -e "${BOLD}Branch:${RESET} $(current_branch)"
  echo -e "${BOLD}Remote:${RESET} $(git remote get-url origin 2>/dev/null || echo 'none')"
  echo
  git status --short --branch
}

menu() {
  while true; do
    clear
    echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║          Stocked Dev Console             ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
    echo -e "Repo: ${DIM}$REPO${RESET}"
    echo -e "Branch: ${GREEN}$(current_branch)${RESET}"
    if dirty_check; then echo -e "Changes: ${YELLOW}uncommitted${RESET}"; else echo -e "Changes: ${DIM}clean${RESET}"; fi
    echo
    echo "  1) Pull latest (current branch)"
    echo "  2) Apply delivery archive  (+ commit + push)"
    echo "  3) Commit & push my changes"
    echo "  4) Switch branch"
    echo "  5) New branch"
    echo "  6) Merge a branch into current"
    echo "  7) List branches"
    echo "  8) Open in Xcode"
    echo "  9) Status"
    echo "  0) Quit"
    echo
    read -r -p "Choose: " choice
    case "$choice" in
      1) pull_current; pause ;;
      2) apply_delivery; pause ;;
      3) commit_push; pause ;;
      4) switch_branch; pause ;;
      5) new_branch; pause ;;
      6) merge_branch; pause ;;
      7) list_branches; pause ;;
      8) open_xcode; pause ;;
      9) status_view; pause ;;
      0|q|Q) echo "Bye."; exit 0 ;;
      *) ;;
    esac
  done
}

require_git
menu
