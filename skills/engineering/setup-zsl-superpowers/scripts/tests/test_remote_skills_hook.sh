#!/usr/bin/env bash
# Tests for remote-skills-hook.sh. Pure shell + real git against a local "zsl"
# repo (file:// URL), with HOME pointed at a sandbox. Asserts: no-op outside a
# remote/runner session, skills linked from ZSL_SUPERPOWERS_REPO, and a cache
# cloned from a DIFFERENT repo is replaced rather than silently reused (the way a
# runner moved from upstream to a fork would keep running upstream's skills).
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/remote-skills-hook.sh"
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

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# make_zsl <dir> <marker> → a git repo on main with skills/engineering/tdd/SKILL.md
make_zsl() {
  mkdir -p "$1/skills/engineering/tdd"
  echo "$2" >"$1/skills/engineering/tdd/SKILL.md"
  git -C "$1" init --quiet -b main && git -C "$1" add . && git -C "$1" commit --quiet -m init
}

T="$(mktemp -d)"
make_zsl "$T/upstream" upstream
make_zsl "$T/fork" fork
run_hook() { HOME="$T/home" CLAUDE_CODE_REMOTE="${2:-true}" ZSL_SUPERPOWERS_REPO="$1" bash "$HOOK" 2>&1; }

# --- 1. Local session (CLAUDE_CODE_REMOTE unset): no-op.
run_hook "file://$T/fork" false >/dev/null
[ -e "$T/home/.claude/skills/tdd" ] && bad "local: no-op" || ok "local: no-op"

# --- 2. Override: skills come from ZSL_SUPERPOWERS_REPO.
run_hook "file://$T/upstream" >/dev/null
assert_eq "override: upstream linked" upstream "$(cat "$T/home/.claude/skills/tdd/SKILL.md")"

# --- 3. Fails-the-old-way: switching to the fork must not reuse the upstream cache.
out="$(run_hook "file://$T/fork")"
assert_eq "switch repo: fork's skills now linked" fork "$(cat "$T/home/.claude/skills/tdd/SKILL.md")"
case "$out" in *"file://$T/fork"*) ok "switch repo: log names the repo" ;; *) bad "switch repo: log names the repo" ;; esac
rm -rf "$T"

echo
if [ "$fails" -eq 0 ]; then
  echo "remote-skills-hook.sh: all tests passed"
  exit 0
else
  echo "remote-skills-hook.sh: $fails assertion(s) failed"
  exit 1
fi
