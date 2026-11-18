#!/usr/bin/env bash
# ~/.local/bin/wakapi-backup.sh  (chmod 700)
set -Eeuo pipefail
umask 077
DEST="${WAKAPI_BACKUP_DIR:-$HOME/workshop/irfanshadikrishad/backups/}"
KEEP=14
mkdir -p "$DEST"

docker stop wakapi >/dev/null
trap 'docker start wakapi >/dev/null' EXIT

docker run --rm -v wakapi-data:/data:ro -v "$DEST":/backup alpine \
  tar czf "/backup/wakapi-data-$(date +%F).tgz" -C /data .

find "$DEST" -maxdepth 1 -type f -name 'wakapi-data-*.tgz' \
  -printf '%T@ %p\n' |
  sort -rn |
  tail -n +$((KEEP + 1)) |
  cut -d' ' -f2- |
  while IFS= read -r file; do
    rm -- "$file"
  done
