#!/usr/bin/env bash
# Restores the Wakapi data volume from the latest backup archive.
#
#   ./wakapi-restore.sh               restore the newest backups/wakapi-data-*.tgz
#   ./wakapi-restore.sh --dry-run     show what would happen, change nothing
#   ./wakapi-restore.sh --file X.tgz  restore a specific archive
#
# DESTRUCTIVE: replaces everything currently in the Wakapi data volume.
# A safety backup of the current data is written first (outside the git repo).
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/backups"
ARCHIVE=""
ASSUME_YES=0
DRY_RUN=0

CONTAINER="${WAKAPI_CONTAINER:-wakapi}"
VOLUME="${WAKAPI_VOLUME:-wakapi-data}"
IMAGE="${HELPER_IMAGE:-alpine:3}"
WAKAPI_URL="${WAKAPI_URL:-http://127.0.0.1:1111}"
SAFETY_DIR="${SAFETY_DIR:-$HOME/backups/wakapi}"

log() { printf '[wakapi-restore] %s\n' "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Usage: wakapi-restore.sh [options]

  -f, --file FILE   restore this archive instead of the newest one
  -d, --dir DIR     folder to search for the newest archive (default: <script folder>/backups)
  -n, --dry-run     show what would happen, change nothing
  -y, --yes         skip the confirmation prompt
  -h, --help        show this help

Environment overrides: WAKAPI_CONTAINER (wakapi), WAKAPI_VOLUME (wakapi-data),
HELPER_IMAGE (alpine:3), WAKAPI_URL (http://127.0.0.1:1111), SAFETY_DIR (~/backups/wakapi)
EOF
}

# ---------- arguments ----------
while (($#)); do
  case "$1" in
  -f | --file)
    [[ $# -ge 2 ]] || die "$1 needs a value"
    ARCHIVE="$2"
    shift 2
    ;;
  -d | --dir)
    [[ $# -ge 2 ]] || die "$1 needs a value"
    BACKUP_DIR="$2"
    shift 2
    ;;
  -y | --yes)
    ASSUME_YES=1
    shift
    ;;
  -n | --dry-run)
    DRY_RUN=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "unknown option: $1 (see --help)" ;;
  esac
done

# ---------- validation ----------
for bin in docker tar find sort tail grep mktemp stat; do
  command -v "$bin" >/dev/null 2>&1 || die "missing dependency: $bin"
done
[[ "$CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "invalid WAKAPI_CONTAINER"
[[ "$VOLUME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "invalid WAKAPI_VOLUME"
[[ "$IMAGE" =~ ^[a-z0-9][a-z0-9._/:-]*$ ]] || die "invalid HELPER_IMAGE"
[[ "$SAFETY_DIR" != *:* ]] || die "SAFETY_DIR must not contain ':'"

# ---------- cleanup ----------
TMPLIST=""
STOPPED=0
DATA_TOUCHED=0
DONE=0
SAFETY_FILE=""
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "$TMPLIST" ]]; then
    rm -f -- "$TMPLIST"
  fi
  if ((STOPPED == 1 && DONE == 0)); then
    if ((DATA_TOUCHED == 0)); then
      # Nothing was changed yet: put Wakapi back exactly as it was.
      if docker start "$CONTAINER" >/dev/null 2>&1; then
        log "Wakapi restarted, your data was not modified"
      else
        log "WARNING: could not restart '$CONTAINER', run: docker start $CONTAINER"
      fi
    else
      log "!!! The restore did NOT finish and Wakapi was NOT restarted."
      log "    Your previous data is saved in: $SAFETY_FILE"
      log "    To go back to it: $0 --file $SAFETY_FILE"
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------- pick the archive ----------
if [[ -z "$ARCHIVE" ]]; then
  [[ -d "$BACKUP_DIR" ]] || die "backup folder not found: $BACKUP_DIR"
  ARCHIVE="$(find "$BACKUP_DIR" -maxdepth 1 -type f -regextype posix-extended \
    -regex '.*/wakapi-data-[0-9]{4}-[0-9]{2}-[0-9]{2}\.tgz' | sort | tail -n 1)"
  [[ -n "$ARCHIVE" ]] || die "no wakapi-data-YYYY-MM-DD.tgz archive found in $BACKUP_DIR"
fi
[[ -f "$ARCHIVE" && -r "$ARCHIVE" ]] || die "archive not readable: $ARCHIVE"
ARCHIVE="$(readlink -f -- "$ARCHIVE")"
ARCHIVE_DIR="$(dirname -- "$ARCHIVE")"
ARCHIVE_NAME="$(basename -- "$ARCHIVE")"
[[ "$ARCHIVE_DIR" != *:* ]] || die "archive folder path must not contain ':'"
[[ -s "$ARCHIVE" ]] || die "archive is empty: $ARCHIVE"

# ---------- verify the archive before touching anything ----------
TMPLIST="$(mktemp)"
tar -tzf "$ARCHIVE" >"$TMPLIST" 2>/dev/null || die "archive is corrupt or not a gzip tar: $ARCHIVE"
[[ -s "$TMPLIST" ]] || die "archive has no entries"
if grep -Eq '(^/|(^|/)\.\.(/|$))' "$TMPLIST"; then
  die "archive contains absolute or '..' paths, refusing to restore it"
fi
ENTRIES="$(wc -l <"$TMPLIST")"

SAFETY_NAME="pre-restore-$(date +%Y%m%d-%H%M%S).tgz"
SAFETY_FILE="$SAFETY_DIR/$SAFETY_NAME"

log "Archive   : $ARCHIVE ($(stat -c '%s' "$ARCHIVE") bytes, $ENTRIES entries)"
log "Volume    : $VOLUME  <- ALL CURRENT DATA IN IT WILL BE REPLACED"
log "Container : $CONTAINER (stopped during the restore, then started again)"
log "Safety    : current data is saved first to $SAFETY_FILE"

if ((DRY_RUN == 1)); then
  log "Dry run: nothing was changed."
  exit 0
fi

# ---------- confirmation ----------
if ((ASSUME_YES == 0)); then
  [[ -t 0 ]] || die "no terminal for the confirmation prompt; use --yes"
  printf 'Type "restore" to continue: ' >&2
  read -r reply
  [[ "$reply" == "restore" ]] || die "cancelled, nothing was changed"
fi

# ---------- preflight (still no changes) ----------
docker volume inspect "$VOLUME" >/dev/null 2>&1 || die "docker volume '$VOLUME' not found"
# Pull the helper image BEFORE stopping Wakapi so downtime stays short.
docker image inspect "$IMAGE" >/dev/null 2>&1 ||
  docker pull --quiet "$IMAGE" >/dev/null 2>&1 || die "cannot pull image $IMAGE"
mkdir -p "$SAFETY_DIR"

EXISTS=0
RUNNING="false"
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  EXISTS=1
  RUNNING="$(docker inspect -f '{{.State.Running}}' "$CONTAINER")"
fi

# ---------- stop Wakapi ----------
if [[ "$RUNNING" == "true" ]]; then
  docker stop "$CONTAINER" >/dev/null || die "could not stop '$CONTAINER', nothing was changed"
  STOPPED=1
fi

# ---------- safety backup of the CURRENT data ----------
docker run --rm -v "$VOLUME":/data:ro -v "$SAFETY_DIR":/backup "$IMAGE" \
  tar czf "/backup/$SAFETY_NAME" -C /data . ||
  die "could not create the safety backup, nothing was changed"
[[ -s "$SAFETY_FILE" ]] || die "safety backup is empty, nothing was changed"
log "Safety backup written: $SAFETY_FILE"

# ---------- restore ----------
DATA_TOUCHED=1
docker run --rm -v "$VOLUME":/data -v "$ARCHIVE_DIR":/backup:ro "$IMAGE" \
  sh -c 'set -e; find /data -mindepth 1 -delete; tar xzf "/backup/$1" -C /data' sh "$ARCHIVE_NAME" ||
  die "restore failed part-way"
DONE=1
log "Data restored from $ARCHIVE_NAME"

# ---------- start Wakapi again ----------
if ((EXISTS == 1)); then
  docker start "$CONTAINER" >/dev/null ||
    die "data restored, but could not start '$CONTAINER': run docker start $CONTAINER"
  if command -v curl >/dev/null 2>&1; then
    up=0
    for _ in $(seq 1 15); do
      if curl --silent --output /dev/null --max-time 2 "${WAKAPI_URL%/}/"; then
        up=1
        break
      fi
      sleep 2
    done
    if ((up == 1)); then
      log "Wakapi is up at $WAKAPI_URL"
    else
      log "WARNING: Wakapi did not answer within 30s, check: docker logs $CONTAINER"
    fi
  fi
else
  log "Container '$CONTAINER' does not exist, recreate it with the docker run command from INSTRUCTION.md"
fi

log "Done. Your previous data is kept in $SAFETY_FILE (delete it once you are happy)."
