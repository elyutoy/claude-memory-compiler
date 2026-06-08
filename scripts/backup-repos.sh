#!/bin/zsh
# Авто-бэкап git-репозиториев Ai Projects.
# Проходит по списку репо: git add -A → коммит (если есть изменения) → push.
# Сбой одного репозитория не останавливает остальные.
# Запускается по cron каждые 2 часа днём; вручную — через скилл /backup-repos.

BASE="/Volumes/Work/Users/geg/Мои проекты/Ai Projects"
HERMES_AGENT="/Volumes/Work/Users/geg/Мои проекты/Hermes Agent"
LOG="$BASE/backup-repos.log"
MAX_BYTES=104857600   # 100 МБ — лимит GitHub; файлы крупнее отвергаются (pre-receive hook)
STATUS_DIR="$HERMES_AGENT/.backup-status"
STATUS_FILE="$STATUS_DIR/github-backup-status.json"
REMOTE_STATUS="/root/.hermes/github-backup-status.json"
CREDENTIALS_FILE="$HERMES_AGENT/sources/promts/install/credentials.txt"
SSH_KEY="/Volumes/Work/Users/geg/.ssh/hermes_dashboard_ed25519"

REPOS=(
  "$BASE/claude-memory-compiler"
  "$BASE/Hybrid System"
  "$BASE/Memory wiki"
  "$BASE/system-config"
  "$HERMES_AGENT"
)

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

read_credential() {
  awk -F= -v key="$1" '
    $1 == key {
      sub(/^[^=]*=/, "")
      sub(/^"/, "")
      sub(/"$/, "")
      print
      exit
    }
  ' "$CREDENTIALS_FILE"
}

write_backup_status() {
  local repo="$1"
  local name="$2"
  local status="$3"
  local detail="$4"
  local remote branch commit

  mkdir -p "$STATUS_DIR" 2>>"$LOG" || return 0
  remote="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  commit="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || true)"

  BACKUP_REPO_NAME="$name" \
  BACKUP_REPO_PATH="$repo" \
  BACKUP_STATUS="$status" \
  BACKUP_DETAIL="$detail" \
  BACKUP_REMOTE="$remote" \
  BACKUP_BRANCH="$branch" \
  BACKUP_COMMIT="$commit" \
  BACKUP_STATUS_FILE="$STATUS_FILE" \
  python3 - <<'PY_STATUS' 2>>"$LOG" || log "[$name] WARNING: backup status write failed"
import json
import os
from datetime import datetime, timezone
from pathlib import Path

path = Path(os.environ["BACKUP_STATUS_FILE"])
try:
    data = json.loads(path.read_text()) if path.exists() else {}
except Exception:
    data = {}
repos = data.setdefault("repositories", {})
name = os.environ["BACKUP_REPO_NAME"]
now = datetime.now(timezone.utc).isoformat()
repos[name] = {
    "status": os.environ["BACKUP_STATUS"],
    "detail": os.environ["BACKUP_DETAIL"],
    "path": os.environ["BACKUP_REPO_PATH"],
    "remote": os.environ["BACKUP_REMOTE"],
    "branch": os.environ["BACKUP_BRANCH"],
    "commit": os.environ["BACKUP_COMMIT"],
    "updated_at": now,
}
data["updated_at"] = now
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY_STATUS
}

sync_backup_status_to_vps() {
  [ -f "$STATUS_FILE" ] || return 0
  [ -r "$SSH_KEY" ] || return 0
  [ -f "$CREDENTIALS_FILE" ] || return 0

  local vps_ip vps_user
  vps_ip="$(read_credential VPS_IP)"
  vps_user="$(read_credential VPS_USER)"
  [ -n "$vps_ip" ] && [ -n "$vps_user" ] || return 0

  if scp -q \
    -i "$SSH_KEY" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/tmp/hermes_agent_known_hosts_ubuntu24 \
    "$STATUS_FILE" "${vps_user}@${vps_ip}:${REMOTE_STATUS}" 2>>"$LOG"; then
    log "[backup-status] synced to VPS"
  else
    log "[backup-status] WARNING: sync to VPS failed"
  fi
}


log "=== старт авто-бэкапа ==="

# Обновить snapshot конфига (~/.claude + launchd) перед бэкапом system-config.
# sync.sh копирует только белый список — секреты сюда не попадают.
if [ -x "$BASE/system-config/sync.sh" ]; then
  "$BASE/system-config/sync.sh" >> "$LOG" 2>&1 && log "[system-config] sync выполнен" || log "[system-config] ОШИБКА sync"
fi

if [ -x "$HERMES_AGENT/bin/snapshot-hermes-vps-settings" ]; then
  "$HERMES_AGENT/bin/snapshot-hermes-vps-settings" >> "$LOG" 2>&1 && log "[Hermes Agent] VPS settings snapshot выполнен" || log "[Hermes Agent] ОШИБКА VPS settings snapshot"
fi

for repo in "${REPOS[@]}"; do
  name="${repo:t}"

  if [ ! -d "$repo/.git" ]; then
    log "[$name] ПРОПУСК — не git-репозиторий"
    write_backup_status "$repo" "$name" "skipped" "not a git repository"
    continue
  fi

  git -C "$repo" add -A 2>>"$LOG"

  # Страховка: исключить из коммита файлы >100 МБ. GitHub отвергает такие пуши
  # (pre-receive hook), из-за чего бэкап молча падал бы на дни. Разстейджим большой
  # файл (он остаётся на диске) и громко логируем — нужно добавить его в .gitignore.
  git -C "$repo" diff --cached --name-only -z | while IFS= read -r -d '' f; do
    size=$(git -C "$repo" cat-file -s ":$f" 2>/dev/null) || continue
    if [ -n "$size" ] && [ "$size" -gt "$MAX_BYTES" ]; then
      git -C "$repo" restore --staged -- "$f" 2>>"$LOG"
      log "[$name] ⚠️ ПРОПУЩЕН файл >100 МБ ($(( size / 1048576 )) МБ): $f — добавьте в .gitignore"
    fi
  done

  if git -C "$repo" diff --cached --quiet; then
    log "[$name] локальных изменений нет"
  else
    count=$(git -C "$repo" diff --cached --name-only | wc -l | tr -d ' ')
    msg="Авто-бэкап $(date '+%Y-%m-%d %H:%M') (${count} файлов)"
    if git -C "$repo" commit -q -m "$msg" 2>>"$LOG"; then
      log "[$name] коммит: $msg"
    else
      log "[$name] ОШИБКА коммита"
      write_backup_status "$repo" "$name" "error" "commit failed"
      continue
    fi
  fi

  # push — всегда, чтобы подхватить и ручные неотправленные коммиты
  if git -C "$repo" remote | grep -q .; then
    if git -C "$repo" push -q 2>>"$LOG"; then
      log "[$name] push выполнен"
      write_backup_status "$repo" "$name" "ok" "push выполнен"
    else
      log "[$name] ОШИБКА push (нет сети/удалённого репозитория?)"
      write_backup_status "$repo" "$name" "error" "push failed"
    fi
  else
    log "[$name] remote не настроен — push пропущен"
    write_backup_status "$repo" "$name" "skipped" "remote not configured"
  fi
done

sync_backup_status_to_vps

log "=== конец авто-бэкапа ==="
