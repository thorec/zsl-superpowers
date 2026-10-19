#!/usr/bin/env bash
# select-due-entry.sh — pick the earliest DUE self-hosted entry from an afk-runs
# ledger, for the self-hosted dispatcher (afk-dispatch.sh). Given a ledger and a
# "now" there is exactly one correct answer, so this owns the selection rule rather
# than leaving "is it time to run PRD X yet?" to judgment.
#
# An entry <root>/<date>/<feature-num>.md is due when ALL hold:
#   - claim: scheduled         (in-progress/done/tracking = already handled)
#   - outcome: pending         (the writer's exact initial value — never "scheduled")
#   - trigger: self-hosted     (claude-routines entries are fired by claude.ai, not us)
#   - slot <= now              (both canonical UTC: YYYY-MM-DDTHH:MM[:SS]Z)
#   - "<date>/<feature-num>" is not listed in --skip-file (already dispatched)
#
# Slots with a numeric offset (+02:00) or any other shape are skipped with a warning
# on stderr — comparing them as strings would be wrong, and guessing is worse.
#
# Prints the earliest due entry as "<slot>\t<date>\t<feature-num>" (slot normalized
# to seconds precision), or nothing when none is due. The date dir is the EVENING
# /afk-fanout ran, so a post-midnight slot is found under the previous day's dir.
#
# Exit 0 on success (including "nothing due"); exit 1 on a missing/invalid argument.
set -uo pipefail

ROOT="" NOW="" SKIP_FILE=""

err() {
  echo "select-due-entry.sh: $1" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: select-due-entry.sh --root <.afk-runs dir> --now YYYY-MM-DDTHH:MM:SSZ \
                           [--skip-file <file of date/feature-num lines>]
EOF
}

# Canonical UTC → seconds precision; anything else → empty (caller treats as invalid).
normalize_ts() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) echo "$1" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]Z) echo "${1%Z}:00Z" ;;
    *) echo "" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      ROOT="${2-}"
      shift 2 || err "missing value for --root"
      ;;
    --now)
      NOW="${2-}"
      shift 2 || err "missing value for --now"
      ;;
    --skip-file)
      SKIP_FILE="${2-}"
      shift 2 || err "missing value for --skip-file"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) err "unknown arg: $1" ;;
  esac
done

[ -n "$ROOT" ] || {
  usage
  err "--root is required"
}
[ -n "$NOW" ] || err "--now is required"
NOW_N="$(normalize_ts "$NOW")"
[ -n "$NOW_N" ] || err "--now must be UTC YYYY-MM-DDTHH:MM[:SS]Z (got: $NOW)"
[ -d "$ROOT" ] || exit 0 # no ledger yet → nothing due

best_slot="" best_date="" best_num=""
for entry in "$ROOT"/*/*.md; do
  [ -f "$entry" ] || continue
  num="$(basename "$entry" .md)"
  case "$num" in _*) continue ;; esac # _scheduled.md is the manifest, not an entry
  date="$(basename "$(dirname "$entry")")"

  grep -qx 'claim: scheduled' "$entry" || continue
  grep -qx 'outcome: pending' "$entry" || {
    grep -q '^outcome: scheduled$' "$entry" &&
      echo "select-due-entry.sh: $date/$num has 'outcome: scheduled' (malformed — expected 'pending'); skipping" >&2
    continue
  }

  meta="$(grep -m1 '^trigger: ' "$entry")" || continue
  trigger="$(printf '%s\n' "$meta" | sed -n 's/^trigger: \([^ ]*\).*/\1/p')"
  [ "$trigger" = "self-hosted" ] || continue

  raw_slot="$(printf '%s\n' "$meta" | sed -n 's/.*slot: \([^ ]*\).*/\1/p')"
  slot="$(normalize_ts "$raw_slot")"
  if [ -z "$slot" ]; then
    echo "select-due-entry.sh: $date/$num slot '$raw_slot' is not canonical UTC (…Z); skipping" >&2
    continue
  fi

  # Same fixed-width canonical form on both sides, so string order == time order.
  [[ "$slot" > "$NOW_N" ]] && continue

  if [ -n "$SKIP_FILE" ] && [ -f "$SKIP_FILE" ] && grep -qx "$date/$num" "$SKIP_FILE"; then
    continue
  fi

  if [ -z "$best_slot" ] || [[ "$slot" < "$best_slot" ]]; then
    best_slot="$slot" best_date="$date" best_num="$num"
  fi
done

[ -n "$best_slot" ] && printf '%s\t%s\t%s\n' "$best_slot" "$best_date" "$best_num"
exit 0
