#!/usr/bin/env bash
# Updates a README block with Wakapi language stats and pushes it to GitHub.
#
# Designed to run hourly from cron (plus once at boot):
#   - at most ONE successful commit per local calendar day
#   - pushes only when the generated stats differ from the last pushed ones
#   - failures never use up the daily quota, so the next run simply retries
set -Eeuo pipefail
umask 077

# CHANGED: resolve the script's own directory so cron's cwd doesn't matter
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

CONFIG_FILE="${WAKAPI_README_CONFIG:-$HOME/.config/wakapi-readme/config.env}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/wakapi-readme"
HASH_FILE="$STATE_DIR/last_hash"
DATE_FILE="$STATE_DIR/last_push_date"
START_MARK='<!--WAKAPI:START-->'
END_MARK='<!--WAKAPI:END-->'

log() { printf '%s [wakapi-readme] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

# ---------- dependencies ----------
# CHANGED: added find, sort, head, cut, cp, tar
for bin in curl jq git awk flock base64 mktemp sha256sum cmp find sort head cut cp tar; do
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
: "${README_REPO:?README_REPO is required, e.g. git@github-wakapi:user/user.git}"
: "${README_BRANCH:=main}"
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
# CHANGED: backup settings (all overridable from config.env)
: "${BACKUP_SCRIPT:=$SCRIPT_DIR/wakapi-backup.sh}"
: "${BACKUP_SRC_DIR:=$SCRIPT_DIR/backups}"
: "${BACKUP_REPO_DIR:=backups}"
: "${BACKUP_KEEP:=0}" # 0 = keep everything; N = keep newest N archives in the repo

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
[[ "$README_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid README_BRANCH"
[[ "$README_FILE" != /* && "$README_FILE" != *..* ]] || die "invalid README_FILE"
# CHANGED: validate backup settings
[[ "$BACKUP_KEEP" =~ ^[0-9]+$ && "$BACKUP_KEEP" -le 3650 ]] || die "BACKUP_KEEP must be 0-3650"
[[ "$BACKUP_REPO_DIR" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$BACKUP_REPO_DIR" != *..* ]] ||
  die "invalid BACKUP_REPO_DIR (must be a relative path inside the repo)"
[[ -x "$BACKUP_SCRIPT" ]] || die "backup script not found or not executable: $BACKUP_SCRIPT"

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

# CHANGED: run the backup script, then copy its newest archive into the repo clone
# stage_backup <repo_dir>
stage_backup() {
  local repo="$1" latest dest_dir
  dest_dir="$repo/$BACKUP_REPO_DIR"

  # Run from the script's dir so relative paths inside the backup script behave the same under cron
  (cd "$SCRIPT_DIR" && "$BACKUP_SCRIPT") || return 1

  latest="$(find "$BACKUP_SRC_DIR" -maxdepth 1 -type f -name 'wakapi-data-*.tgz' \
    -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
  [[ -n "$latest" && -f "$latest" ]] || {
    log "no wakapi-data-*.tgz found in $BACKUP_SRC_DIR"
    return 1
  }
  # Refuse to publish a corrupt archive
  tar -tzf "$latest" >/dev/null 2>&1 || {
    log "backup archive failed integrity check: $latest"
    return 1
  }

  mkdir -p "$dest_dir"
  cp -f -- "$latest" "$dest_dir/$(basename -- "$latest")"

  # Optional retention: keep only the newest BACKUP_KEEP archives inside the repo
  if ((BACKUP_KEEP > 0)); then
    local old
    while IFS= read -r old; do
      [[ -n "$old" ]] && rm -f -- "$old"
    done < <(find "$dest_dir" -maxdepth 1 -type f -name 'wakapi-data-*.tgz' -printf '%T@ %p\n' |
      sort -nr | tail -n +"$((BACKUP_KEEP + 1))" | cut -d' ' -f2-)
  fi
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
trap 'rm -rf "$TMP"' EXIT

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

# ---------- sync repo ----------
REPO_DIR="$STATE_DIR/repo"
export GIT_TERMINAL_PROMPT=0
if [[ ! -d "$REPO_DIR/.git" ]]; then
  retry git clone --quiet --depth 1 --branch "$README_BRANCH" "$README_REPO" "$REPO_DIR" ||
    die "git clone failed"
fi
retry git -C "$REPO_DIR" fetch --quiet --depth 1 origin "$README_BRANCH" || die "git fetch failed"
git -C "$REPO_DIR" reset --quiet --hard "origin/$README_BRANCH"

TARGET="$REPO_DIR/$README_FILE"
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

# README on GitHub already has this exact block: record it, but no commit
# happens, so today's daily quota is NOT used.
if cmp -s "$TMP/README.new" "$TARGET"; then
  write_state "$HASH_FILE" "$NEW_HASH"
  log "README already up to date, nothing to commit"
  exit 0
fi

# CHANGED: backup now runs via an absolute path and lands inside the clone that gets committed
stage_backup "$REPO_DIR" || die "backup failed"

cat "$TMP/README.new" >"$TARGET"
# CHANGED: stage the README and the backup dir, and warn if the backup was not staged (e.g. .gitignore)
git -C "$REPO_DIR" add -- "$README_FILE"
git -C "$REPO_DIR" add -A -- "$BACKUP_REPO_DIR" ||
  log "WARNING: could not stage $BACKUP_REPO_DIR (ignored by .gitignore?)"
if git -C "$REPO_DIR" diff --cached --quiet -- "$BACKUP_REPO_DIR"; then
  log "WARNING: no backup changes staged in $BACKUP_REPO_DIR (check .gitignore for *.tgz or backups/)"
fi
git -C "$REPO_DIR" \
  -c user.name="$GIT_AUTHOR_NAME_CFG" -c user.email="$GIT_AUTHOR_EMAIL_CFG" \
  commit --quiet -m "chore: update coding stats ($TODAY)"
retry git -C "$REPO_DIR" push --quiet origin "HEAD:$README_BRANCH" || die "git push failed"

# State is saved ONLY after a successful push, so any failure above retries next run.
write_state "$HASH_FILE" "$NEW_HASH"
write_state "$DATE_FILE" "$TODAY"
log "README updated and pushed (daily push done for $TODAY)"
