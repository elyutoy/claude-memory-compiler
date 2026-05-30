#!/bin/zsh
# Авто-бэкап git-репозиториев Ai Projects.
# Проходит по списку репо: git add -A → коммит (если есть изменения) → push.
# Сбой одного репозитория не останавливает остальные.
# Запускается по cron каждые 2 часа днём; вручную — через скилл /backup-repos.

BASE="/Volumes/Work/Users/geg/Мои проекты/Ai Projects"
LOG="$BASE/backup-repos.log"
MAX_BYTES=104857600   # 100 МБ — лимит GitHub; файлы крупнее отвергаются (pre-receive hook)

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
