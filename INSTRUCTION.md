#### Wakapi README Stats: Local Setup Guide

Track your coding time with [Wakapi](https://github.com/muety/wakapi) running **locally on your own Linux machine**, then automatically publish your top languages to your GitHub README **every hour, only when the stats actually change**.

No paid service. No public server. Your data stays on your machine.

---

#### Table of contents

1. [What you get](#1-what-you-get)
2. [How it works](#2-how-it-works)
3. [Requirements](#3-requirements)
4. [Step 1: Install prerequisites](#step-1-install-prerequisites)
5. [Step 2: Run Wakapi locally](#step-2-run-wakapi-locally)
6. [Step 3: Create your account and API key](#step-3-create-your-account-and-api-key)
7. [Step 4: Connect your editor](#step-4-connect-your-editor)
8. [Step 5: Give the script GitHub access](#step-5-give-the-script-github-access)
9. [Step 6: Add markers to your README](#step-6-add-markers-to-your-readme)
10. [Step 7: Install the script](#step-7-install-the-script)
11. [Step 8: Create the config file](#step-8-create-the-config-file)
12. [Step 9: Verify the API response](#step-9-verify-the-api-response)
13. [Step 10: Dry run](#step-10-dry-run)
14. [Step 11: Schedule it hourly](#step-11-schedule-it-hourly)
15. [Customizing the output](#customizing-the-output)
16. [Maintenance](#maintenance)
17. [Troubleshooting](#troubleshooting)
18. [Security notes](#security-notes)
19. [Uninstall](#uninstall)

---

#### 1. What you get

A block in your README that looks like this and refreshes itself:

```text
TypeScript  12h 41m  ███████████░░░░░░░░░░░░░░   45.2%
Python       6h 10m  ██████░░░░░░░░░░░░░░░░░░░   22.0%
Bash         3h 02m  ███░░░░░░░░░░░░░░░░░░░░░░   10.8%
```

- Runs every hour via cron.
- Pushes a commit **only** when the displayed stats change (no empty commits).
- Configurable: number of languages, excluded languages, minimum percentage, bar width, time range.

#### 2. How it works

```
editor plugin  →  Wakapi (Docker, 127.0.0.1:1111)  ←  script (cron, hourly)  →  git push  →  GitHub README
```

- Your editor's WakaTime plugin sends activity ("heartbeats") to your local Wakapi.
- GitHub Actions **cannot** reach `localhost`, so the script runs on your own computer instead.
- The script fetches stats, builds a text block, compares it with the last pushed version, and pushes only if different.

**Limitations to know up front**

- Stats update only while your computer is on. Cron skips runs when it is off or asleep; the next run after it wakes catches up automatically.
- A local Wakapi instance only sees activity from the machine(s) whose editors point at it.

#### 3. Requirements

- Ubuntu / Debian-based Linux (other distros work with equivalent packages)
- Docker
- A GitHub repository with a `README.md` (a profile repo named `YOUR_USER/YOUR_USER` works well)
- An editor with the [WakaTime plugin](https://wakatime.com/plugins)
- Terminal shell: bash or zsh (all commands below work in both)

---

#### Step 1: Install prerequisites

```bash
sudo apt update && sudo apt install -y curl jq git openssl
docker --version || echo "Docker is NOT installed"
```

If Docker is missing, install it by following the official Docker docs for Ubuntu, then allow your user to run it without `sudo` and **log out and back in**:

```bash
sudo usermod -aG docker "$USER"
```

Check that port **1111** is free (change the port everywhere in this guide if it is not):

```bash
ss -ltnH 'sport = :1111' | grep -q . && echo "1111 is IN USE" || echo "1111 is free"
```

---

#### Step 2: Run Wakapi locally

This creates a private config with a random password salt, then starts Wakapi bound to **localhost only** on port 1111 (so it is not exposed to your network and does not clash with services on 3000/3001).

```bash
mkdir -p ~/.config/wakapi && chmod 700 ~/.config/wakapi

# Generate the salt ONCE. Changing it later breaks existing passwords.
if [ ! -f ~/.config/wakapi/env ]; then
  ( umask 077
    cat > ~/.config/wakapi/env <<EOF
WAKAPI_PASSWORD_SALT=$(openssl rand -hex 32)
WAKAPI_PUBLIC_URL=http://localhost:1111
EOF
  )
fi
chmod 600 ~/.config/wakapi/env

docker run -d --init \
  --name wakapi \
  --restart unless-stopped \
  -p 127.0.0.1:1111:3000 \
  --env-file ~/.config/wakapi/env \
  -v wakapi-data:/data \
  ghcr.io/muety/wakapi:latest
```

Check it:

```bash
docker port wakapi      # expect: 3000/tcp -> 127.0.0.1:1111
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:1111/api/health
```

The health check should print `200`. If not, run `docker logs wakapi`.

> **Important:** keep the `127.0.0.1:` prefix in `-p 127.0.0.1:1111:3000`. Docker-published ports can bypass UFW firewall rules; the prefix is what keeps the port off your network.

> **Never** run `docker volume rm wakapi-data` or `docker rm -v wakapi`. That deletes your history.

---

#### Step 3: Create your account and API key

1. Open <http://localhost:1111> and sign up.
2. Go to **Settings** and copy your **API key**. You will use it in Steps 4 and 8.

---

#### Step 4: Connect your editor

Install the standard WakaTime plugin for your editor, then create or edit `~/.wakatime.cfg`:

```ini
[settings]
api_url = http://localhost:1111/api
api_key = PASTE_YOUR_WAKAPI_API_KEY
```

Restart your editor and code for a few minutes. Open <http://localhost:1111> and confirm activity appears on the dashboard.

---

#### Step 5: Give the script GitHub access

Use a dedicated SSH **deploy key** limited to a single repository (safer than a personal access token).

```bash
ssh-keygen -t ed25519 -f ~/.ssh/wakapi_readme -N "" -C "wakapi-readme"
cat ~/.ssh/wakapi_readme.pub
```

1. On GitHub, open your README repository.
2. Go to **Settings → Deploy keys → Add deploy key**.
3. Paste the public key and tick **Allow write access**.

Add this to `~/.ssh/config` (create the file if needed):

```
Host github-wakapi
  HostName github.com
  User git
  IdentityFile ~/.ssh/wakapi_readme
  IdentitiesOnly yes
```

```bash
chmod 700 ~/.ssh && chmod 600 ~/.ssh/config ~/.ssh/wakapi_readme
```

Run this **once** to accept GitHub's host key. Compare the fingerprint it shows with GitHub's published fingerprints before typing `yes`; cron cannot answer this prompt later.

```bash
ssh -T git@github-wakapi
```

A message saying you successfully authenticated (and that GitHub does not provide shell access) means it works.

---

#### Step 6: Add markers to your README

In your repository's `README.md`, add these two lines where the stats should appear:

```markdown
<!--WAKAPI:START-->
<!--WAKAPI:END-->
```

Commit and push this change. The script replaces everything between the markers and refuses to run if they are missing.

---

#### Step 7: Install the script

```bash
mkdir -p ~/.local/bin ~/.local/state/wakapi-readme
nano ~/.local/bin/wakapi-readme.sh
```

Paste the following, save, then make it executable:

````bash
#!/usr/bin/env bash
# Updates a README block with Wakapi language stats and pushes it to GitHub.
# Skips all git/network work when the generated stats are unchanged.
set -Eeuo pipefail
umask 077

CONFIG_FILE="${WAKAPI_README_CONFIG:-$HOME/.config/wakapi-readme/config.env}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/wakapi-readme"
HASH_FILE="$STATE_DIR/last_hash"
START_MARK='<!--WAKAPI:START-->'
END_MARK='<!--WAKAPI:END-->'

log() { printf '%s [wakapi-readme] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------- dependencies ----------
for bin in curl jq git awk flock base64 mktemp sha256sum cmp; do
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
: "${GIT_AUTHOR_NAME_CFG:=wakapi-readme-bot}"
: "${GIT_AUTHOR_EMAIL_CFG:?GIT_AUTHOR_EMAIL_CFG is required}"
: "${FORCE:=0}"

case "$STATS_RANGE" in
  today|yesterday|week|month|year|7_days|last_7_days|30_days|last_30_days|6_months|last_6_months|12_months|last_12_months|last_year|all_time) ;;
  *) die "invalid STATS_RANGE: $STATS_RANGE" ;;
esac
[[ "$TOP_N" =~ ^[0-9]+$ && "$TOP_N" -ge 1 && "$TOP_N" -le 50 ]] || die "TOP_N must be 1-50"
[[ "$BAR_WIDTH" =~ ^[0-9]+$ && "$BAR_WIDTH" -ge 5 && "$BAR_WIDTH" -le 50 ]] || die "BAR_WIDTH must be 5-50"
[[ "$SHOW_TOTAL" == "0" || "$SHOW_TOTAL" == "1" ]] || die "SHOW_TOTAL must be 0 or 1"
[[ "$MIN_PERCENT" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
  && awk -v p="$MIN_PERCENT" 'BEGIN { exit !(p <= 100) }' \
  || die "MIN_PERCENT must be a number between 0 and 100"
[[ "$README_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid README_BRANCH"
[[ "$README_FILE" != /* && "$README_FILE" != *..* ]] || die "invalid README_FILE"

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || { log "another run is in progress, exiting"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

fetch_stats > "$TMP/stats.json" || die "could not fetch stats from Wakapi (is it running?)"
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
' "$TMP/stats.json" > "$TMP/langs.tsv"

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
} > "$TMP/block.md"

# ---------- change detection (skip everything else if unchanged) ----------
NEW_HASH="$(sha256sum "$TMP/block.md" | cut -d' ' -f1)"
OLD_HASH=""
[[ -r "$HASH_FILE" ]] && OLD_HASH="$(< "$HASH_FILE")"

save_hash() {
  printf '%s\n' "$NEW_HASH" > "$HASH_FILE.tmp" && mv -f "$HASH_FILE.tmp" "$HASH_FILE"
}

if [[ "$FORCE" != "1" && "$NEW_HASH" == "$OLD_HASH" ]]; then
  log "stats unchanged, skipping"
  exit 0
fi
log "stats changed (or forced), updating README"

# ---------- sync repo ----------
REPO_DIR="$STATE_DIR/repo"
export GIT_TERMINAL_PROMPT=0
if [[ ! -d "$REPO_DIR/.git" ]]; then
  git clone --quiet --depth 1 --branch "$README_BRANCH" "$README_REPO" "$REPO_DIR" \
    || die "git clone failed"
fi
git -C "$REPO_DIR" fetch --quiet --depth 1 origin "$README_BRANCH" || die "git fetch failed"
git -C "$REPO_DIR" reset --quiet --hard "origin/$README_BRANCH"

TARGET="$REPO_DIR/$README_FILE"
[[ -f "$TARGET" ]] || die "$README_FILE not found in repo"
grep -qxF "$START_MARK" "$TARGET" && grep -qxF "$END_MARK" "$TARGET" \
  || die "markers $START_MARK / $END_MARK not found in $README_FILE"

# ---------- replace block ----------
awk -v s="$START_MARK" -v e="$END_MARK" -v bf="$TMP/block.md" '
  $0 == s { print; while ((getline line < bf) > 0) print line; close(bf); skip = 1; next }
  $0 == e { skip = 0 }
  !skip   { print }
' "$TARGET" > "$TMP/README.new"

[[ -s "$TMP/README.new" ]] || die "generated README is empty, aborting"

# README on GitHub already has this exact block: just record it, no commit.
if cmp -s "$TMP/README.new" "$TARGET"; then
  save_hash
  log "README already up to date, nothing to commit"
  exit 0
fi

cat "$TMP/README.new" > "$TARGET"
git -C "$REPO_DIR" add -- "$README_FILE"
git -C "$REPO_DIR" \
  -c user.name="$GIT_AUTHOR_NAME_CFG" -c user.email="$GIT_AUTHOR_EMAIL_CFG" \
  commit --quiet -m "chore: update coding stats"
git -C "$REPO_DIR" push --quiet origin "HEAD:$README_BRANCH" || die "git push failed"

save_hash   # only after a successful push, so failures retry next run
log "README updated and pushed"
````

```bash
chmod 700 ~/.local/bin/wakapi-readme.sh
```

---

#### Step 8: Create the config file

```bash
mkdir -p ~/.config/wakapi-readme && chmod 700 ~/.config/wakapi-readme
( umask 077; nano ~/.config/wakapi-readme/config.env )
chmod 600 ~/.config/wakapi-readme/config.env
```

Paste this and replace the placeholders:

```bash
# --- connection ---
WAKAPI_URL="http://127.0.0.1:1111"
WAKAPI_API_KEY="PASTE_YOUR_WAKAPI_API_KEY"

# --- GitHub target ---
README_REPO="git@github-wakapi:YOUR_USER/YOUR_REPO.git"
README_BRANCH="main"
README_FILE="README.md"
GIT_AUTHOR_EMAIL_CFG="YOUR_ID+YOUR_USER@users.noreply.github.com"

# --- data ---
STATS_RANGE="last_7_days"

# --- display options (all optional, defaults shown) ---
TOP_N=5
EXCLUDE_LANGUAGES=""
MIN_PERCENT=0
BAR_WIDTH=25
SHOW_TOTAL=0
```

Notes:

- For a profile README, `YOUR_REPO` is the same as your username.
- `README_BRANCH` must match your repository's default branch (`main` or `master`).
- Find your GitHub noreply email under **GitHub → Settings → Emails**.
- The script refuses to run unless this file is `chmod 600`.

---

#### Step 9: Verify the API response

The script assumes Wakapi returns the WakaTime-style shape (`.data.languages[]` with `name` and `total_seconds`). Confirm that on your instance before scheduling anything.

This works in bash and zsh:

```bash
printf 'Wakapi API key: '; read -rs KEY; echo

curl -sS -o /tmp/wakapi_stats.json -w 'HTTP %{http_code}\n' \
  -H "Authorization: Basic $(printf '%s' "$KEY" | base64 -w0)" \
  http://127.0.0.1:1111/api/compat/wakatime/v1/users/current/stats/last_7_days

unset KEY
jq '.data.languages[:2]' /tmp/wakapi_stats.json
rm -f /tmp/wakapi_stats.json
```

| Output                                             | Meaning                                                            |
| -------------------------------------------------- | ------------------------------------------------------------------ |
| `HTTP 200` + entries with `name` / `total_seconds` | Good. Continue.                                                    |
| `HTTP 200` + `[]` or `null`                        | No data yet. Code for a few more minutes, retry.                   |
| `HTTP 401`                                         | Wrong or empty key. Re-copy it from Wakapi Settings.               |
| `HTTP 000` / connection refused                    | Wakapi is not running. Check `docker ps` and `docker logs wakapi`. |
| `HTTP 200` + different field names                 | Adjust the `jq` section of the script to match.                    |

---

#### Step 10: Dry run

```bash
~/.local/bin/wakapi-readme.sh     # first run: "stats changed", pushes to GitHub
~/.local/bin/wakapi-readme.sh     # second run: "stats unchanged, skipping"
```

Open your repository on GitHub and confirm the block appeared between the markers.

---

#### Step 11: Schedule it hourly

```bash
crontab -e
```

Add:

```cron
0 * * * * $HOME/.local/bin/wakapi-readme.sh >> $HOME/.local/state/wakapi-readme/run.log 2>&1
```

Optional: a weekly job that keeps the log from growing forever (keeps the last 500 lines):

```cron
0 3 * * 0 tail -n 500 $HOME/.local/state/wakapi-readme/run.log > $HOME/.local/state/wakapi-readme/run.log.tmp && mv $HOME/.local/state/wakapi-readme/run.log.tmp $HOME/.local/state/wakapi-readme/run.log
```

Confirm it saved and watch results:

```bash
crontab -l
tail -f ~/.local/state/wakapi-readme/run.log
```

Typical log lines:

```
[wakapi-readme] stats unchanged, skipping
[wakapi-readme] stats changed (or forced), updating README
[wakapi-readme] README updated and pushed
```

---

#### Customizing the output

Edit `~/.config/wakapi-readme/config.env`. The next hourly run picks it up and pushes automatically (the changed output changes the hash). To apply immediately, run the script by hand.

| Option              | Default       | What it does                                                                 |
| ------------------- | ------------- | ---------------------------------------------------------------------------- |
| `TOP_N`             | `5`           | How many languages to show (1-50)                                            |
| `EXCLUDE_LANGUAGES` | empty         | Comma-separated names to hide, case-insensitive, e.g. `"Text,Markdown,JSON"` |
| `MIN_PERCENT`       | `0`           | Hide languages below this share, e.g. `1` hides anything under 1%            |
| `BAR_WIDTH`         | `25`          | Width of the progress bar (5-50)                                             |
| `SHOW_TOTAL`        | `0`           | `1` adds a "Total: Xh YYm" line                                              |
| `STATS_RANGE`       | `last_7_days` | Time window (see below)                                                      |

**Order of operations:** exclude languages → recompute percentages over what remains → sort → drop anything under `MIN_PERCENT` → take the top `TOP_N`. Percentages are therefore relative to the languages you chose to show.

**Valid `STATS_RANGE` values:** `today`, `yesterday`, `week`, `month`, `year`, `7_days`, `last_7_days`, `30_days`, `last_30_days`, `6_months`, `last_6_months`, `12_months`, `last_12_months`, `last_year`, `all_time`.

**Find the exact language names Wakapi uses** (names must match, e.g. `Shell` vs `Bash`). This runs in a subshell so your key does not leak into your session:

```bash
( source ~/.config/wakapi-readme/config.env
  printf 'header = "Authorization: Basic %s"\n' "$(printf '%s' "$WAKAPI_API_KEY" | base64 -w0)" |
    curl -sS --fail --config - \
      "${WAKAPI_URL%/}/api/compat/wakatime/v1/users/current/stats/${STATS_RANGE:-last_7_days}" \
    | jq -r '.data.languages[].name' )
```

`EXCLUDE_LANGUAGES` matches whole names only. Excluding `Java` will not hide `JavaScript`.

**Example config for a tidy, developer-focused list:**

```bash
STATS_RANGE="last_30_days"
TOP_N=8
EXCLUDE_LANGUAGES="Text,Markdown,JSON,YAML"
MIN_PERCENT=1
SHOW_TOTAL=1
```

**Force a regenerate** (for example after editing the README by hand):

```bash
FORCE=1 ~/.local/bin/wakapi-readme.sh
```

---

#### Maintenance

**Update Wakapi** (your data lives in the `wakapi-data` volume and is kept):

```bash
docker pull ghcr.io/muety/wakapi:latest
docker rm -f wakapi
docker run -d --init \
  --name wakapi \
  --restart unless-stopped \
  -p 127.0.0.1:1111:3000 \
  --env-file ~/.config/wakapi/env \
  -v wakapi-data:/data \
  ghcr.io/muety/wakapi:latest
```

**Back up your data:**

```bash
docker run --rm -v wakapi-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/wakapi-data-$(date +%F).tgz -C /data .
```

Also keep a copy of `~/.config/wakapi/env`. Without the same salt, existing passwords stop working.

**Change the port** (the container must be recreated because published ports are fixed at creation time): remove the container with `docker rm -f wakapi`, rerun the `docker run` command from Step 2 with a different `-p 127.0.0.1:NEWPORT:3000`, then update `api_url` in `~/.wakatime.cfg` and `WAKAPI_URL` in the script config.

**Check status:**

```bash
docker ps --filter name=wakapi
tail -n 20 ~/.local/state/wakapi-readme/run.log
```

---

#### Troubleshooting

| Symptom                                      | Fix                                                                                                                                                                              |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `read: -p: no coprocess`                     | You are in zsh. Use `printf 'Prompt: '; read -rs VAR` as shown in Step 9.                                                                                                        |
| `jq: parse error` on the API check           | The request was unauthenticated or the server returned an error page. Check the HTTP code and key.                                                                               |
| `could not fetch stats from Wakapi`          | Wakapi is not running: `docker ps`, `docker logs wakapi`.                                                                                                                        |
| `git clone failed`                           | Redo Step 5. The deploy key needs **write access** and you must have run `ssh -T git@github-wakapi` once.                                                                        |
| `git push failed`                            | Check the branch name, that the deploy key has write access, and that the branch is not protected against pushes. The hash is only saved after success, so the next run retries. |
| `markers ... not found`                      | Push the two marker lines from Step 6 and match the exact text.                                                                                                                  |
| `config must be chmod 600`                   | `chmod 600 ~/.config/wakapi-readme/config.env`                                                                                                                                   |
| `invalid STATS_RANGE` / `TOP_N must be 1-50` | Fix the value in the config; the script validates before doing any work.                                                                                                         |
| Stats never change                           | Confirm editors are sending data (dashboard at `http://localhost:1111`). Wakapi's own data is fine if the dashboard shows activity.                                              |
| Cron seems to do nothing                     | `crontab -l`, check the log file path exists, and use absolute paths.                                                                                                            |
| Output shows no languages                    | You may have excluded everything or set `MIN_PERCENT` too high.                                                                                                                  |

---

#### Security notes

- **Localhost only:** Wakapi is bound to `127.0.0.1`. Do not remove the prefix.
- **Secrets in files with strict permissions:** the config (`chmod 600`) holds your API key; `~/.config/wakapi/env` holds your salt.
- **No secrets in process lists or URLs:** the script passes the API key to curl through stdin, not command-line arguments.
- **Least-privilege GitHub access:** a deploy key limited to one repository, rather than a broad personal access token.
- **Validated inputs:** every config value is checked before use, and output text is sanitized so it cannot break your README formatting.
- **Single instance:** `flock` stops overlapping runs from racing each other.
- **Atomic state:** the change-detection hash is only saved after a successful push.
- Consider disabling new signups in Wakapi once your account exists. Check `config.default.yml` in the Wakapi repository for the current option name.

---

#### Uninstall

```bash
# Remove cron entries: run `crontab -e` and delete the wakapi-readme lines

# Remove the script, config and state
rm -rf ~/.local/bin/wakapi-readme.sh ~/.config/wakapi-readme ~/.local/state/wakapi-readme

# Stop Wakapi (keeps your data volume)
docker rm -f wakapi

# ONLY if you want to delete all coding history permanently:
# docker volume rm wakapi-data

# Remove the deploy key from GitHub (repo Settings → Deploy keys), then:
rm -f ~/.ssh/wakapi_readme ~/.ssh/wakapi_readme.pub
# and delete the "Host github-wakapi" block from ~/.ssh/config
```

Finally, remove the `<!--WAKAPI:START-->` / `<!--WAKAPI:END-->` block from your README and the `api_url` line from `~/.wakatime.cfg`.
