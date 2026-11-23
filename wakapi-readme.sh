#!/usr/bin/env bash
# Updates a README block with Wakapi language stats and pushes it to GitHub.
#
# Runs directly inside the git working copy that contains this script.
#   - at most ONE successful commit per local calendar day
#   - pushes only when the generated stats differ from the last pushed ones
#   - failures never use up the daily quota, so the next run simply retries
#   - only README_FILE and the newest backup archive are ever committed
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

CONFIG_FILE="${WAKAPI_README_CONFIG:-$HOME/.config/wakapi-readme/config.env}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/wakapi-readme"
HASH_FILE="$STATE_DIR/last_hash"
DATE_FILE="$STATE_DIR/last_push_date"
START_MARK='<!--WAKAPI:START-->'
END_MARK='<!--WAKAPI:END-->'

TMP=""
REPO_DIR=""
README_FILE=""
BACKUP_REPO_DIR=""
ROLLBACK=0
COMMITTED=0
BACKUP_REL=""

log() { printf '%s [wakapi-readme] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

# On any failure after the working tree was touched, restore it to a clean state.
cleanup() {
  local rc=$?
  if ((rc != 0 && ROLLBACK == 1)) && [[ -n "$REPO_DIR" ]]; then
    log "rolling back local changes"
    if ((COMMITTED == 1)); then
      git -C "$REPO_DIR" reset -q --soft HEAD~1 || true
    fi
    git -C "$REPO_DIR" reset -q -- "$README_FILE" "$BACKUP_REPO_DIR" 2>/dev/null || true
    git -C "$REPO_DIR" checkout -q -- "$README_FILE" 2>/dev/null || true
  fi
  [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"
  return "$rc"
}
trap cleanup EXIT

# ---------- dependencies ----------
for bin in curl jq git awk flock base64 mktemp sha256sum cmp find sort head cut tar basename; do
  command -v "$bin" >/dev/null 2>&1 || die "missing dependency: $bin"
done

# ---------- config ----------
[[ -r "$CONFIG_FILE" ]] || die "config not found: $CONFIG_FILE"
perm="$(stat -c '%a' "$CONFIG_FILE")"
[[ "$perm" == "600" || "$perm" == "400" ]] || die "config must be chmod 600 (is $perm)"
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${WAKAPI_URL:=http://127.0.0.1:1111}"
: "${WAKAPI_API_KEY:?WAKAPI_API_KEY is required}"
: "${WAKAPI_REPO_DIR:=$SCRIPT_DIR}"
: "${README_REPO:=}" # optional: URL/host-alias used for fetch+push instead of the remote
: "${README_REMOTE:=origin}"
: "${README_BRANCH:=}" # default: currently checked-out branch
: "${README_FILE:=README.md}"
: "${STATS_RANGE:=last_7_days}"
: "${TOP_N:=5}"
: "${EXCLUDE_LANGUAGES:=}"
: "${MIN_PERCENT:=0}"
: "${BAR_WIDTH:=25}"
: "${SHOW_TOTAL:=0}"
: "${WAIT_FOR_WAKAPI:=0}"
: "${NET_RETRIES:=4}"
: "${NET_RETRY_DELAY:=15}"
: "${GIT_AUTHOR_NAME_CFG:=wakapi-readme-bot}"
: "${GIT_AUTHOR_EMAIL_CFG:?GIT_AUTHOR_EMAIL_CFG is required}"
: "${FORCE:=0}"
: "${BACKUP_SCRIPT:=$SCRIPT_DIR/wakapi-backup.sh}"
: "${BACKUP_REPO_DIR:=backups}" # relative to the repo root
: "${BACKUP_FORCE_ADD:=0}"      # 1 = git add -f (bypass .gitignore) for the archive

case "$STATS_RANGE" in
today | yesterday | week | month | year | 7_days | last_7_days | 30_days | last_30_days | 6_months | last_6_months | 12_months | last_12_months | last_year | all_time) ;;
*) die "invalid STATS_RANGE: $STATS_RANGE" ;;
esac
[[ "$TOP_N" =~ ^[0-9]+$ && "$TOP_N" -ge 1 && "$TOP_N" -le 50 ]] || die "TOP_N must be 1-50"
[[ "$BAR_WIDTH" =~ ^[0-9]+$ && "$BAR_WIDTH" -ge 5 && "$BAR_WIDTH" -le 50 ]] || die "BAR_WIDTH must be 5-50"
[[ "$SHOW_TOTAL" == "0" || "$SHOW_TOTAL" == "1" ]] || die "SHOW_TOTAL must be 0 or 1"
[[ "$MIN_PERCENT" =~ ^[0-9]+(\.[0-9]+)?$ ]] &&
  awk -v p="$MIN_PERCENT" 'BEGIN { exit !(p <= 100) }' ||
  die "MIN_PERCENT must be a number between 0 and 100"
[[ "$WAIT_FOR_WAKAPI" =~ ^[0-9]+$ && "$WAIT_FOR_WAKAPI" -le 600 ]] || die "WAIT_FOR_WAKAPI must be 0-600"
[[ "$NET_RETRIES" =~ ^[0-9]+$ && "$NET_RETRIES" -ge 1 && "$NET_RETRIES" -le 10 ]] || die "NET_RETRIES must be 1-10"
[[ "$NET_RETRY_DELAY" =~ ^[0-9]+$ && "$NET_RETRY_DELAY" -ge 1 && "$NET_RETRY_DELAY" -le 120 ]] || die "NET_RETRY_DELAY must be 1-120"
[[ "$README_FILE" != /* && "$README_FILE" != *..* ]] || die "invalid README_FILE"
[[ "$BACKUP_FORCE_ADD" == "0" || "$BACKUP_FORCE_ADD" == "1" ]] || die "BACKUP_FORCE_ADD must be 0 or 1"
[[ "$BACKUP_REPO_DIR" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$BACKUP_REPO_DIR" != *..* ]] ||
  die "invalid BACKUP_REPO_DIR (must be a relative path inside the repo)"
[[ -x "$BACKUP_SCRIPT" ]] || die "backup script not found or not executable: $BACKUP_SCRIPT"

# ---------- resolve the working copy ----------
REPO_DIR="$(git -C "$WAKAPI_REPO_DIR" rev-parse --show-toplevel 2>/dev/null)" ||
  die "not a git repository: $WAKAPI_REPO_DIR"
CURRENT_BRANCH="$(git -C "$REPO_DIR" symbolic-ref --short -q HEAD)" ||
  die "detached HEAD in $REPO_DIR; check out a branch"
: "${README_BRANCH:=$CURRENT_BRANCH}"
[[ "$README_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid README_BRANCH"
[[ "$README_BRANCH" == "$CURRENT_BRANCH" ]] ||
  die "checked-out branch is '$CURRENT_BRANCH' but README_BRANCH is '$README_BRANCH'"
SYNC_TARGET="${README_REPO:-$README_REMOTE}"
TARGET="$REPO_DIR/$README_FILE"
BACKUP_ABS="$REPO_DIR/$BACKUP_REPO_DIR"

# ---------- helpers ----------
# retry <command...>: run a command up to NET_RETRIES times (network hiccups after boot/resume)
retry() {
  local attempt=1
  until "$@"; do
    if ((attempt >= NET_RETRIES)); then
      return 1
    fi
    log "attempt $attempt/$NET_RETRIES failed (${1} ${2:-}), retrying in ${NET_RETRY_DELAY}s"
    sleep "$NET_RETRY_DELAY"
    attempt=$((attempt + 1))
  done
}

# write_state <file> <value>: atomic single-line state write
write_state() {
  printf '%s\n' "$2" >"$1.tmp" && mv -f "$1.tmp" "$1"
}

# wait_for_wakapi: any HTTP response from the server counts as "up"
wait_for_wakapi() {
  local deadline=$((SECONDS + WAIT_FOR_WAKAPI))
  until curl --silent --output /dev/null --max-time 3 --proto '=http,https' "${WAKAPI_URL%/}/"; do
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 5
  done
}

# run_backup: run the backup script, locate + verify the newest archive, set BACKUP_REL
run_backup() {
  local latest
  (cd "$SCRIPT_DIR" && "$BACKUP_SCRIPT") || return 1

  latest="$(find "$BACKUP_ABS" -maxdepth 1 -type f -name 'wakapi-data-*.tgz' \
    -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
  [[ -n "$latest" && -f "$latest" ]] || {
    log "no wakapi-data-*.tgz found in $BACKUP_ABS"
    return 1
  }
  tar -tzf "$latest" >/dev/null 2>&1 || {
    log "backup archive failed integrity check: $latest"
    return 1
  }
  BACKUP_REL="$BACKUP_REPO_DIR/$(basename -- "$latest")"
}

# ---------- single instance ----------
mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || {
  log "another run is in progress, exiting"
  exit 0
}

# ---------- daily limit (checked first: no network work if already pushed today) ----------
TODAY="$(date +%F)"
LAST_PUSH_DATE=""
if [[ -r "$DATE_FILE" ]]; then
  LAST_PUSH_DATE="$(<"$DATE_FILE")"
  [[ "$LAST_PUSH_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || LAST_PUSH_DATE=""
fi

if [[ "$FORCE" != "1" && "$LAST_PUSH_DATE" == "$TODAY" ]]; then
  log "already pushed today ($TODAY), skipping"
  exit 0
fi

TMP="$(mktemp -d)"

# ---------- wait for Wakapi (useful right after boot) ----------
if ((WAIT_FOR_WAKAPI > 0)); then
  wait_for_wakapi || log "Wakapi not reachable after ${WAIT_FOR_WAKAPI}s, trying anyway"
fi

# ---------- fetch stats (key never appears in argv or the URL) ----------
fetch_stats() {
  local url="${WAKAPI_URL%/}/api/compat/wakatime/v1/users/current/stats/${STATS_RANGE}"
  local auth
  auth="$(printf '%s' "$WAKAPI_API_KEY" | base64 -w0)"
  printf 'header = "Authorization: Basic %s"\n' "$auth" |
    curl --silent --show-error --fail \
      --max-time 20 --retry 3 --retry-connrefused \
      --proto '=http,https' --config - "$url"
}

fetch_stats >"$TMP/stats.json" || die "could not fetch stats from Wakapi (is it running?)"
jq -e '.data' "$TMP/stats.json" >/dev/null 2>&1 || die "unexpected API response shape"

# ---------- build markdown block ----------
# 1) exclude languages, 2) recompute percentages over what remains, 3) sort
jq -r --arg exclude "$EXCLUDE_LANGUAGES" '
  ($exclude | split(",")
            | map(gsub("^\\s+|\\s+$"; "") | ascii_downcase)
            | map(select(length > 0))) as $ex
  | ((.data.languages // [])
      | map(select(((.name // "Unknown") | ascii_downcase) as $n
                   | (($ex | any(. == $n)) | not)))) as $l
  | ([$l[] | (.total_seconds // 0)] | add // 0) as $total
  | $l | sort_by(-(.total_seconds // 0)) | .[]
  | [ ((.name // "Unknown") | gsub("[\\t\\n\\r`|]"; " ")),
      (.total_seconds // 0),
      (if $total > 0 then ((.total_seconds // 0) * 100 / $total) else 0 end) ]
  | @tsv
' "$TMP/stats.json" >"$TMP/langs.tsv"

# 4) apply MIN_PERCENT, then TOP_N, then render
{
  echo '```text'
  awk -F'\t' -v n="$TOP_N" -v minp="$MIN_PERCENT" -v bw="$BAR_WIDTH" -v st="$SHOW_TOTAL" '
    { all += $2 }
    ($3 + 0) >= (minp + 0) && cnt < n {
      cnt++; name[cnt] = $1; secs[cnt] = $2 + 0; pct[cnt] = $3 + 0
      if (length($1) > w) w = length($1)
    }
    END {
      if (cnt == 0) { print "No activity recorded in this period."; exit }
      for (i = 1; i <= cnt; i++) {
        h = int(secs[i] / 3600); m = int((secs[i] % 3600) / 60)
        filled = int(pct[i] * bw / 100); bar = ""
        for (j = 0; j < bw; j++) bar = bar (j < filled ? "█" : "░")
        printf "%-*s  %4dh %02dm  %s  %5.1f%%\n", w, name[i], h, m, bar, pct[i]
      }
      if (st == 1) {
        printf "\nTotal: %dh %02dm\n", int(all / 3600), int((all % 3600) / 60)
      }
    }' "$TMP/langs.tsv"
  echo '```'
} >"$TMP/block.md"

# ---------- change detection (skip git/network if the block is unchanged) ----------
NEW_HASH="$(sha256sum "$TMP/block.md" | cut -d' ' -f1)"
OLD_HASH=""
[[ -r "$HASH_FILE" ]] && OLD_HASH="$(<"$HASH_FILE")"

if [[ "$FORCE" != "1" && "$NEW_HASH" == "$OLD_HASH" ]]; then
  log "stats unchanged, skipping"
  exit 0
fi
log "stats changed (or forced), updating README"

# ---------- sync working copy (never destructive) ----------
export GIT_TERMINAL_PROMPT=0

git -C "$REPO_DIR" ls-files --error-unmatch -- "$README_FILE" >/dev/null 2>&1 ||
  die "$README_FILE is not tracked in $REPO_DIR"
git -C "$REPO_DIR" diff --quiet HEAD -- "$README_FILE" ||
  die "$README_FILE has uncommitted changes; commit or stash them first"

retry git -C "$REPO_DIR" fetch --quiet "$SYNC_TARGET" "$README_BRANCH" || die "git fetch failed"
git -C "$REPO_DIR" merge --ff-only --quiet FETCH_HEAD ||
  die "cannot fast-forward '$README_BRANCH' (diverged or conflicting local files); resolve manually"

[[ -f "$TARGET" ]] || die "$README_FILE not found in repo"
grep -qxF "$START_MARK" "$TARGET" && grep -qxF "$END_MARK" "$TARGET" ||
  die "markers $START_MARK / $END_MARK not found in $README_FILE"

# ---------- replace block ----------
awk -v s="$START_MARK" -v e="$END_MARK" -v bf="$TMP/block.md" '
  $0 == s { print; while ((getline line < bf) > 0) print line; close(bf); skip = 1; next }
  $0 == e { skip = 0 }
  !skip   { print }
' "$TARGET" >"$TMP/README.new"

[[ -s "$TMP/README.new" ]] || die "generated README is empty, aborting"

# README already has this exact block: record it, but no commit happens,
# so today's daily quota is NOT used.
if cmp -s "$TMP/README.new" "$TARGET"; then
  write_state "$HASH_FILE" "$NEW_HASH"
  log "README already up to date, nothing to commit"
  exit 0
fi

# ---------- backup + stage + commit + push ----------
run_backup || die "backup failed"

ROLLBACK=1
cat "$TMP/README.new" >"$TARGET"
git -C "$REPO_DIR" add -- "$README_FILE"
COMMIT_PATHS=("$README_FILE")

if git -C "$REPO_DIR" check-ignore -q -- "$BACKUP_REL"; then
  if [[ "$BACKUP_FORCE_ADD" == "1" ]]; then
    git -C "$REPO_DIR" add -f -- "$BACKUP_REL"
  else
    log "WARNING: $BACKUP_REL is ignored by .gitignore, so it will NOT be committed."
    log "         Fix the rule (see: git check-ignore -v $BACKUP_REL) or set BACKUP_FORCE_ADD=1"
  fi
else
  git -C "$REPO_DIR" add -- "$BACKUP_REL"
fi

if [[ -n "$(git -C "$REPO_DIR" ls-files -- "$BACKUP_REL")" ]]; then
  COMMIT_PATHS+=("$BACKUP_REL")
fi

# Explicit pathspec: only these files are committed, whatever else is staged in the repo.
git -C "$REPO_DIR" \
  -c user.name="$GIT_AUTHOR_NAME_CFG" -c user.email="$GIT_AUTHOR_EMAIL_CFG" \
  commit --quiet -m "chore: update coding stats ($TODAY)" -- "${COMMIT_PATHS[@]}"
COMMITTED=1

retry git -C "$REPO_DIR" push --quiet "$SYNC_TARGET" "HEAD:$README_BRANCH" || die "git push failed"
ROLLBACK=0

# State is saved ONLY after a successful push, so any failure above retries next run.
write_state "$HASH_FILE" "$NEW_HASH"
write_state "$DATE_FILE" "$TODAY"
log "README updated and pushed (daily push done for $TODAY; committed: ${COMMIT_PATHS[*]})"
