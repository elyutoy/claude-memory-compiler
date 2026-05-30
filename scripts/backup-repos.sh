#!/bin/zsh
# Авто-бэкап git-репозиториев Ai Projects.
# Проходит по списку репо: git add -A → коммит (если есть изменения) → push.
# Сбой одного репозитория не останавливает остальные.
# Запускается по cron каждые 2 часа днём; вручную — через скилл /backup-repos.

BASE="/Volumes/Work/Users/geg/Мои проекты/Ai Projects"
LOG="$BASE/backup-repos.log"

REPOS=(
  "$BASE/claude-memory-compiler"
  "$BASE/Hybrid System"
  "$BASE/Memory wiki"
  "$BASE/system-config"
)

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

log "=== старт авто-бэкапа ==="

# Обновить snapshot конфига (~/.claude + launchd) перед бэкапом system-config.
# sync.sh копирует только белый список — секреты сюда не попадают.
if [ -x "$BASE/system-config/sync.sh" ]; then
  "$BASE/system-config/sync.sh" >> "$LOG" 2>&1 && log "[system-config] sync выполнен" || log "[system-config] ОШИБКА sync"
fi

for repo in "${REPOS[@]}"; do
  name="${repo:t}"

  if [ ! -d "$repo/.git" ]; then
    log "[$name] ПРОПУСК — не git-репозиторий"
    continue
  fi

  git -C "$repo" add -A 2>>"$LOG"

  if git -C "$repo" diff --cached --quiet; then
    log "[$name] локальных изменений нет"
  else
    count=$(git -C "$repo" diff --cached --name-only | wc -l | tr -d ' ')
    msg="Авто-бэкап $(date '+%Y-%m-%d %H:%M') (${count} файлов)"
    if git -C "$repo" commit -q -m "$msg" 2>>"$LOG"; then
      log "[$name] коммит: $msg"
    else
      log "[$name] ОШИБКА коммита"
      continue
    fi
  fi

  # push — всегда, чтобы подхватить и ручные неотправленные коммиты
  if git -C "$repo" remote | grep -q .; then
    if git -C "$repo" push -q 2>>"$LOG"; then
      log "[$name] push выполнен"
    else
      log "[$name] ОШИБКА push (нет сети/удалённого репозитория?)"
    fi
  else
    log "[$name] remote не настроен — push пропущен"
  fi
done

log "=== конец авто-бэкапа ==="
