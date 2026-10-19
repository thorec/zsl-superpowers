#!/usr/bin/env bash
# Tests for afk-dispatch.sh. Pure shell + real git against a local bare "origin"
# (file:// URL), with `claude` replaced by a stub (AFK_CLAUDE) that records how it was
# invoked and plays the worker's part (flip the ledger claim and push). Asserts the
# runner contract: one due entry per tick, never a re-run, never two workers at once,
# and a stuck run's clone kept for inspection.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="$SCRIPT_DIR/afk-dispatch.sh"
WRITER="$SCRIPT_DIR/../../afk-fanout/scripts/write-afk-entry.sh"
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

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# setup <final-claim> → a sandbox with an origin holding main + an afk-runs ledger
# (PRDs 023 @20:07 and 041 @22:07, both self-hosted), and a claude stub that sets
# PRD's ledger claim to <final-claim>.
setup() {
  T="$(mktemp -d)"
  git init --quiet --bare "$T/origin.git"
  git clone --quiet "$T/origin.git" "$T/seed" 2>/dev/null
  (
    cd "$T/seed" || exit 1
    git commit --quiet --allow-empty -m init && git push --quiet origin HEAD:main
    git checkout --quiet --orphan afk-runs && git rm -rq --cached . 2>/dev/null
    bash "$WRITER" --date 2026-05-31 --feature-num 023 --title A --slot 2026-05-31T20:07:00Z \
      --trigger-id self-hosted --routine-url - >/dev/null
    bash "$WRITER" --date 2026-05-31 --feature-num 041 --title B --slot 2026-05-31T22:07:00Z \
      --trigger-id self-hosted --routine-url - >/dev/null
    git add .afk-runs && git commit --quiet -m ledger && git push --quiet origin afk-runs
  )
  cat >"$T/claude-stub" <<EOF
#!/usr/bin/env bash
# Record the invocation, then play the worker: flip this PRD's claim and push.
num="\${2#/afk-worker }"
printf 'args=%s|cwd=%s|date=%s|ref=%s|max=%s\n' "\$*" "\$PWD" "\$AFK_RUN_DATE" "\$AFK_RUN_REF" "\${AFK_MAX:-}" >>"$T/calls"
git -C "$T/seed" checkout --quiet afk-runs
sed -i.bak "s/^claim: scheduled\$/claim: $1/" "$T/seed/.afk-runs/\$AFK_RUN_DATE/\$num.md"
rm -f "$T/seed/.afk-runs/\$AFK_RUN_DATE/\$num.md.bak"
git -C "$T/seed" commit --quiet -am "worker \$num" && git -C "$T/seed" push --quiet origin afk-runs
exit 0
EOF
  chmod +x "$T/claude-stub"
  : >"$T/hook"
  cat >"$T/env" <<EOF
AFK_REPOS=file://$T/origin.git
AFK_WORK_DIR=$T/work
AFK_LOG_DIR=$T/logs
AFK_STATE_DIR=$T/state
AFK_CLAUDE=$T/claude-stub
AFK_SKILLS_HOOK=$T/hook
AFK_MAX=1
EOF
}
tick() { AFK_ENV_FILE="$T/env" AFK_NOW="$1" bash "$DISPATCH" 2>&1; }
calls() { [ -f "$T/calls" ] && wc -l <"$T/calls" | tr -d ' ' || echo 0; }

# --- 1. Before the first slot: nothing runs.
setup "done"
out="$(tick 2026-05-31T19:00:00Z)"
assert_contains "early: says nothing due" "$out" "nothing due"
assert_eq "early: claude not invoked" 0 "$(calls)"

# --- 2. First slot due: exactly PRD 023 runs, headless, in a fresh clone, with env.
out="$(tick 2026-05-31T20:10:00Z)"
assert_eq "due: one invocation" 1 "$(calls)"
call="$(cat "$T/calls")"
assert_contains "due: runs /afk-worker 023" "$call" "args=-p /afk-worker 023 --permission-mode bypassPermissions"
assert_contains "due: cwd is the fresh clone" "$call" "cwd=$T/work/"
assert_contains "due: AFK_RUN_DATE is the ledger date" "$call" "date=2026-05-31"
assert_contains "due: AFK_RUN_REF points at the log" "$call" "ref=$(hostname):$T/logs/"
assert_contains "due: AFK_MAX passed through" "$call" "max=1"
[ -d "$T/work/$(ls "$T/work")/.git" ] && ok "due: clone is a git checkout" || bad "due: clone is a git checkout"

# --- 3. Same time again: 023 is done and 041 isn't due → no re-run.
tick 2026-05-31T20:25:00Z >/dev/null
assert_eq "re-tick: no re-run" 1 "$(calls)"

# --- 4. Second slot due: 041 runs next.
tick 2026-05-31T22:10:00Z >/dev/null
assert_eq "second slot: two invocations" 2 "$(calls)"
assert_contains "second slot: runs 041" "$(tail -1 "$T/calls")" "/afk-worker 041"
[ -d "$T/state/lock.d" ] && bad "lock: released after run" || ok "lock: released after run"
rm -rf "$T"

# --- 5. Fails-the-prose-way: a worker that dies before claiming leaves the ledger
#        `scheduled` — "it's still scheduled and due, run it" would loop every tick.
setup scheduled
tick 2026-05-31T20:10:00Z >/dev/null
tick 2026-05-31T20:25:00Z >/dev/null
assert_eq "unclaimed crash: dispatched once, not every tick" 1 "$(calls)"
rm -rf "$T"

# --- 6. One worker at a time: a live lock holder makes the tick a no-op.
setup "done"
mkdir -p "$T/state/lock.d" && echo $$ >"$T/state/lock.d/pid"
out="$(tick 2026-05-31T20:10:00Z)"
assert_contains "busy: skips while a worker runs" "$out" "already running"
assert_eq "busy: claude not invoked" 0 "$(calls)"
# ...but a stale lock (dead pid) is cleared and the tick proceeds.
echo 999999 >"$T/state/lock.d/pid"
tick 2026-05-31T20:10:00Z >/dev/null
assert_eq "stale lock: cleared and dispatched" 1 "$(calls)"
rm -rf "$T"

# --- 7. A stuck run (claim left in-progress, e.g. halt-3e) keeps its clone.
setup in-progress
tick 2026-05-31T20:10:00Z >/dev/null
clone="$T/work/$(ls "$T/work")"
[ -f "$clone/.afk-keep" ] && ok "stuck: clone marked .afk-keep" || bad "stuck: clone marked .afk-keep"
rm -rf "$T"

# --- 8. Config boundary: no AFK_REPOS → exit 1 with a pointer to the env file.
out="$(AFK_ENV_FILE=/nonexistent AFK_REPOS="" bash "$DISPATCH" 2>&1)"
code=$?
assert_eq "no repos: exit 1" 1 "$code"
assert_contains "no repos: message" "$out" "AFK_REPOS is empty"

echo
if [ "$fails" -eq 0 ]; then
  echo "afk-dispatch.sh: all tests passed"
  exit 0
else
  echo "afk-dispatch.sh: $fails assertion(s) failed"
  exit 1
fi
