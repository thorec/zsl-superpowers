#!/usr/bin/env bash
# Tests for select-due-entry.sh. Pure shell. Builds ledgers with the real writer
# (afk-fanout/scripts/write-afk-entry.sh) so the reader and writer can't drift, then
# asserts the selection rule — including the ways a judgment call gets it wrong:
# running a slot that isn't due yet, missing a post-midnight slot filed under the
# previous evening's dir, dispatching an `outcome: scheduled` slip or a
# claude-routines entry, and string-comparing a non-UTC slot.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECT="$SCRIPT_DIR/select-due-entry.sh"
WRITER="$SCRIPT_DIR/../../afk-fanout/scripts/write-afk-entry.sh"
TAB=$'\t'
fails=0

note() { printf '  %s\n' "$1"; }
ok() { printf 'ok   - %s\n' "$1"; }
bad() {
  printf 'FAIL - %s\n' "$1"
  fails=$((fails + 1))
}
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else
    bad "$1"
    note "expected: $2"
    note "actual:   $3"
  fi
}
assert_contains() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *)
      bad "$1"
      note "missing: $3"
      note "in:      $2"
      ;;
  esac
}

# entry <root> <date> <num> <slot> [trigger]
entry() {
  bash "$WRITER" --root "$1" --date "$2" --feature-num "$3" --title "PRD $3" \
    --slot "$4" --trigger-id "${5:-self-hosted}" --routine-url - >/dev/null
}
select_due() { bash "$SELECT" --root "$1" --now "$2" "${@:3}" 2>/dev/null; }

# --- 1. Due vs not-yet-due: only the slot at/before now is picked.
work="$(mktemp -d)"
entry "$work" 2026-05-31 023 "2026-05-31T20:07:00Z"
entry "$work" 2026-05-31 041 "2026-05-31T22:07:00Z"
assert_eq "due: picks the slot that has passed" "2026-05-31T20:07:00Z${TAB}2026-05-31${TAB}023" \
  "$(select_due "$work" 2026-05-31T21:00:00Z)"
assert_eq "not due: nothing before the first slot" "" "$(select_due "$work" 2026-05-31T20:06:59Z)"
assert_eq "boundary: slot == now is due" "2026-05-31T20:07:00Z${TAB}2026-05-31${TAB}023" \
  "$(select_due "$work" 2026-05-31T20:07:00Z)"

# --- 2. Two due entries: the earliest slot wins.
assert_eq "earliest: 023 before 041 once both are due" "2026-05-31T20:07:00Z${TAB}2026-05-31${TAB}023" \
  "$(select_due "$work" 2026-06-01T03:00:00Z)"

# --- 3. Skip file: an already-dispatched entry is passed over for the next one.
printf '2026-05-31/023\n' >"$work/skip"
assert_eq "skip-file: dispatched entry skipped" "2026-05-31T22:07:00Z${TAB}2026-05-31${TAB}041" \
  "$(select_due "$work" 2026-06-01T03:00:00Z --skip-file "$work/skip")"
rm -rf "$work"

# --- 4. Post-midnight slot lives under the previous evening's dir and is still found.
work="$(mktemp -d)"
entry "$work" 2026-05-31 058 "2026-06-01T00:07:00Z"
assert_eq "post-midnight: found under the fanout date" "2026-06-01T00:07:00Z${TAB}2026-05-31${TAB}058" \
  "$(select_due "$work" 2026-06-01T00:30:00Z)"
rm -rf "$work"

# --- 5. Lifecycle: an entry the worker already claimed is never re-dispatched.
work="$(mktemp -d)"
entry "$work" 2026-05-31 023 "2026-05-31T20:07:00Z"
sed -i.bak 's/^claim: scheduled$/claim: in-progress/' "$work/2026-05-31/023.md"
assert_eq "claimed: in-progress entry not picked" "" "$(select_due "$work" 2026-06-01T03:00:00Z)"
rm -rf "$work"

# --- 6. Fails-the-prose-way: `outcome: scheduled` (the writer's known slip) is not
#        dispatched, and the reader says why.
work="$(mktemp -d)"
entry "$work" 2026-05-31 023 "2026-05-31T20:07:00Z"
sed -i.bak 's/^outcome: pending$/outcome: scheduled/' "$work/2026-05-31/023.md"
assert_eq "outcome-slip: not dispatched" "" "$(select_due "$work" 2026-06-01T03:00:00Z)"
err="$(bash "$SELECT" --root "$work" --now 2026-06-01T03:00:00Z 2>&1 >/dev/null)"
assert_contains "outcome-slip: warns" "$err" "outcome: scheduled"
rm -rf "$work"

# --- 7. claude-routines entries belong to claude.ai — never dispatched here.
work="$(mktemp -d)"
entry "$work" 2026-05-31 023 "2026-05-31T20:07:00Z" trg_abc
assert_eq "routine entry: not dispatched" "" "$(select_due "$work" 2026-06-01T03:00:00Z)"
rm -rf "$work"

# --- 8. Fails-the-prose-way: an offset slot (+02:00) would compare wrong as a string
#        ("…T21:30+02:00" is 19:30Z, before 20:00Z) — skip it with a warning instead.
work="$(mktemp -d)"
entry "$work" 2026-05-31 023 "2026-05-31T21:30:00+02:00"
assert_eq "offset slot: not dispatched" "" "$(select_due "$work" 2026-05-31T20:00:00Z)"
err="$(bash "$SELECT" --root "$work" --now 2026-05-31T20:00:00Z 2>&1 >/dev/null)"
assert_contains "offset slot: warns" "$err" "not canonical UTC"

# --- 9. Minute-precision slots normalize to seconds.
work2="$(mktemp -d)"
entry "$work2" 2026-05-31 023 "2026-05-31T20:07Z"
assert_eq "minute precision: normalized + due" "2026-05-31T20:07:00Z${TAB}2026-05-31${TAB}023" \
  "$(select_due "$work2" 2026-05-31T20:07:00Z)"
rm -rf "$work" "$work2"

# --- 10. The manifest (_scheduled.md) is never treated as an entry; missing root is fine.
work="$(mktemp -d)"
entry "$work" 2026-05-31 023 "2026-05-31T20:07:00Z"
out="$(select_due "$work" 2026-06-01T03:00:00Z)"
case "$out" in *_scheduled*) bad "manifest: not an entry" ;; *) ok "manifest: not an entry" ;; esac
assert_eq "missing root: nothing due" "" "$(select_due "$work/nope" 2026-06-01T03:00:00Z)"
rm -rf "$work"

# --- 11. Validation boundary: bad --now → exit 1.
out="$(bash "$SELECT" --root /tmp --now "2026-05-31 20:00" 2>&1)"
code=$?
assert_eq "bad-now: exit 1" 1 "$code"
assert_contains "bad-now: message" "$out" "--now must be UTC"

echo
if [ "$fails" -eq 0 ]; then
  echo "select-due-entry.sh: all tests passed"
  exit 0
else
  echo "select-due-entry.sh: $fails assertion(s) failed"
  exit 1
fi
