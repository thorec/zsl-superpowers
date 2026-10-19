#!/usr/bin/env bash
# afk-dispatch.sh — the self-hosted overnight runner. Run it from cron every ~15 min
# on a machine you own; it replaces the claude.ai routine for repos whose
# docs/agents/remote-env.md says `runner: self-hosted`. The model can be anything
# Claude Code can talk to (Anthropic, or MiniMax via ANTHROPIC_BASE_URL).
#
# Each tick:
#   1. takes a lock — at most ONE worker runs on this machine at a time; a tick that
#      finds a live worker exits 0 and lets the next tick try again;
#   2. refreshes each repo's afk-runs ledger and asks select-due-entry.sh for the
#      earliest due `trigger: self-hosted` entry (claim scheduled, slot <= now);
#   3. records it as dispatched (so a crashed worker is never re-run in a loop),
#      clones the repo fresh, provisions the skills via remote-skills-hook.sh, and runs
#      `claude -p "/afk-worker <num>"` headless in that clone, logging to a file;
#   4. keeps the clone of a stuck run (claim still in-progress, e.g. halt-3e) for
#      inspection and prunes other clones older than AFK_KEEP_DAYS.
#
# The worker owns the ledger lifecycle (scheduled → in-progress → done|tracking);
# this script only reads the ledger. Config comes from an env file (see
# docs/self-hosted-runner.md for the template):
#   AFK_REPOS          space-separated repo URLs to watch (required)
#   AFK_WORK_DIR       clones            (default ~/afk/work)
#   AFK_LOG_DIR        per-run logs      (default ~/afk/logs)
#   AFK_STATE_DIR      lock, ledgers, dispatched list (default ~/afk/state)
#   AFK_KEEP_DAYS      prune clones older than this (default 7)
#   AFK_TIMEOUT_HOURS  kill a worker after this long, if `timeout` exists (default 6)
#   AFK_MAX            passed through to /afk-worker → /tdd-parallel --max
#   ZSL_SUPERPOWERS_REPO / _REF  where the skills hook fetches skills from
#                      (default: the repo this dispatcher's own checkout came from)
#   ANTHROPIC_* / GH_TOKEN / AFK_TELEGRAM_*  passed through to the worker
# Test seams: AFK_NOW, AFK_CLAUDE, AFK_SKILLS_HOOK.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '%s afk-dispatch: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"; }
die() {
  log "$1"
  exit 1
}

ENV_FILE="${AFK_ENV_FILE:-$HOME/.config/zsl-afk/env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

[ -n "${AFK_REPOS:-}" ] || die "AFK_REPOS is empty — set it in $ENV_FILE"
WORK_DIR="${AFK_WORK_DIR:-$HOME/afk/work}"
LOG_DIR="${AFK_LOG_DIR:-$HOME/afk/logs}"
STATE_DIR="${AFK_STATE_DIR:-$HOME/afk/state}"
KEEP_DAYS="${AFK_KEEP_DAYS:-7}"
TIMEOUT_HOURS="${AFK_TIMEOUT_HOURS:-6}"
CLAUDE_BIN="${AFK_CLAUDE:-claude}"
SKILLS_HOOK="${AFK_SKILLS_HOOK:-$SCRIPT_DIR/../../../engineering/setup-zsl-superpowers/remote-skills-hook.sh}"
SELECT="$SCRIPT_DIR/select-due-entry.sh"
mkdir -p "$WORK_DIR" "$LOG_DIR" "$STATE_DIR/ledgers"

notify() { # best-effort, never fails the run
  [ -n "${AFK_TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${AFK_TELEGRAM_CHAT_ID:-}" ] &&
    curl -s --max-time 10 "https://api.telegram.org/bot${AFK_TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${AFK_TELEGRAM_CHAT_ID}" -d text="$1" >/dev/null 2>&1
  return 0
}

# --- 1. One worker at a time. mkdir is atomic everywhere (flock isn't on macOS).
LOCK="$STATE_DIR/lock.d"
if ! mkdir "$LOCK" 2>/dev/null; then
  pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "worker already running (pid $pid) — skipping this tick"
    exit 0
  fi
  log "removing stale lock (pid ${pid:-?} not running)"
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

NOW="${AFK_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

repo_key() { # https://github.com/o/r(.git) → github.com_o_r
  local k="${1#*://}"
  k="${k%.git}"
  printf '%s' "$k" | tr '/:@' '___'
}

refresh_ledger() { # $1 url, $2 dir → 0 if the afk-runs branch is present
  if [ -d "$2/.git" ]; then
    git -C "$2" fetch --quiet --depth 1 origin afk-runs 2>/dev/null &&
      git -C "$2" reset --quiet --hard FETCH_HEAD
  else
    git clone --quiet --depth 1 --single-branch --branch afk-runs "$1" "$2" 2>/dev/null
  fi
}

# --- 2. Earliest due entry across every watched repo.
candidates=""
for url in $AFK_REPOS; do
  key="$(repo_key "$url")"
  ledger="$STATE_DIR/ledgers/$key"
  if ! refresh_ledger "$url" "$ledger"; then
    log "$key: no afk-runs branch yet — skipping"
    continue
  fi
  hit="$(bash "$SELECT" --root "$ledger/.afk-runs" --now "$NOW" \
    --skip-file "$STATE_DIR/$key.dispatched")" || die "select-due-entry.sh failed for $key"
  [ -n "$hit" ] && candidates="${candidates}${hit}"$'\t'"${url}"$'\t'"${key}"$'\n'
done

if [ -z "$candidates" ]; then
  log "nothing due at $NOW"
  exit 0
fi
IFS=$'\t' read -r slot date num url key <<<"$(printf '%s' "$candidates" | sort | head -1)"
run_id="$key-$date-$num"
log "dispatching PRD $num ($key, slot $slot)"

# --- 3. Mark first, so a worker that dies before claiming isn't re-run every tick.
echo "$date/$num" >>"$STATE_DIR/$key.dispatched"

# Prune old clones (never a kept one) before adding a new one.
find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" 2>/dev/null |
  while read -r d; do [ -f "$d/.afk-keep" ] || rm -rf "$d"; done

clone="$WORK_DIR/$run_id"
run_log="$LOG_DIR/$run_id.log"
rm -rf "$clone"
if ! git clone --quiet "$url" "$clone" >>"$run_log" 2>&1; then
  notify "afk-dispatch: PRD $num — clone of $key failed (see $(hostname):$run_log)"
  die "clone failed — see $run_log"
fi

# Provision skills from the same zsl-superpowers this dispatcher runs from, so a
# runner set up from a fork/copy runs that copy's skills, not upstream's.
if [ -z "${ZSL_SUPERPOWERS_REPO:-}" ]; then
  ZSL_SUPERPOWERS_REPO="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
  [ -n "$ZSL_SUPERPOWERS_REPO" ] && export ZSL_SUPERPOWERS_REPO
fi

if [ -f "$SKILLS_HOOK" ]; then
  CLAUDE_CODE_REMOTE=true bash "$SKILLS_HOOK" >>"$run_log" 2>&1 ||
    log "skills hook failed — /afk-worker may not resolve (see $run_log)"
else
  log "skills hook not found at $SKILLS_HOOK — relying on skills already installed"
fi

timeout_cmd=()
if command -v timeout >/dev/null 2>&1; then
  timeout_cmd=(timeout "${TIMEOUT_HOURS}h")
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_cmd=(gtimeout "${TIMEOUT_HOURS}h")
fi

AFK_RUN_DATE="$date"
AFK_RUN_REF="$(hostname):$run_log"
export AFK_RUN_DATE AFK_RUN_REF
(cd "$clone" && ${timeout_cmd[@]+"${timeout_cmd[@]}"} "$CLAUDE_BIN" -p "/afk-worker $num" \
  --permission-mode bypassPermissions) >>"$run_log" 2>&1
rc=$?
log "worker for PRD $num exited $rc — log: $run_log"

# --- 4. Read the outcome back: keep stuck clones, flag workers that never claimed.
entry=""
refresh_ledger "$url" "$STATE_DIR/ledgers/$key" &&
  entry="$(cat "$STATE_DIR/ledgers/$key/.afk-runs/$date/$num.md" 2>/dev/null || true)"
case "$entry" in
  *"claim: in-progress"*)
    touch "$clone/.afk-keep"
    log "PRD $num left in-progress — keeping $clone for inspection"
    ;;
  *"claim: scheduled"*)
    notify "afk-dispatch: PRD $num — worker exited $rc without claiming (see $(hostname):$run_log)"
    ;;
esac
[ "$rc" -eq 0 ] || notify "afk-dispatch: PRD $num — worker exited $rc (see $(hostname):$run_log)"
exit 0
