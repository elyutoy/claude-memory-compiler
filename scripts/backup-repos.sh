#!/bin/zsh
# Авто-бэкап git-репозиториев Ai Projects.
# Проходит по списку репо: git add -A → коммит (если есть изменения) → push.
# Сбой одного репозитория не останавливает остальные.
# Запускается по cron каждые 2 часа днём; вручную — через скилл /backup-repos.

# ⛔ Hermes Agent убран из бэкапа полностью 2026-08-15 (проект закрыт, ведётся не здесь).
# Не возвращать: ни в REPOS, ни snapshot-шагом, ни хранилищем статуса. Вместе с ним ушёл
# весь механизм github-backup-status.json — он писался ВНУТРЬ того репозитория и синкался
# на его дашборд; потребителей в Ai Projects нет (проверено grep-ом 15.08). Заодно это
# снимает причину самоблокировки гейта: snapshot писал в репозиторий за секунды до проверки.
#
# Путь можно переопределить окружением — нужно только тестам (прогон на песочнице
# вместо боевых репозиториев); в cron переменная не задана и берётся значение по умолчанию.
BASE="${BACKUP_BASE:-/Volumes/Work/Users/geg/Мои проекты/Ai Projects}"
LOG="$BASE/backup-repos.log"

MAX_BYTES=104857600   # 100 МБ — лимит GitHub; файлы крупнее отвергаются (pre-receive hook)

# Токен GitHub — абсолютным путём, а не через ~. Из cron у задания нет пригодного HOME:
# git не находит ~/.gitconfig, не подключает helper `store` и спрашивает логин у терминала,
# которого нет — `could not read Username ... Device not configured`. Из-за этого push
# молча не проходил месяцами: коммиты ложились локально, а на GitHub не уезжали.
GIT_CREDENTIALS="/Users/elyutoy/.git-credentials"
GIT_AUTH=(-c "credential.helper=store --file=$GIT_CREDENTIALS")

REPOS=(
  "$BASE/claude-memory-compiler"
  "$BASE/Hybrid System"
  "$BASE/Memory wiki"
  "$BASE/system-config"
)

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

# Ротация лога: держим последние MAX_LOG_LINES строк, чтобы файл не рос бесконечно.
MAX_LOG_LINES=1000
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt "$MAX_LOG_LINES" ]; then
  tail -n "$MAX_LOG_LINES" "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

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

  # Гейт активного редактирования: если репозиторий сейчас правят (есть изменения
  # и самый свежий изменённый файл моложе GUARD_MIN минут) — пропускаем этот проход,
  # чтобы авто-бэкап не перехватывал работу в процессе своим генерик-сообщением
  # «Авто-бэкап» (и не пушил полуготовое). Простаивающие незакоммиченные правки
  # back-up-нутся в следующий проход, когда редактирование утихнет.
  GUARD_MIN=30
  changed_files=("${(@f)$(git -C "$repo" ls-files -m -o --exclude-standard 2>/dev/null)}")
  if [ -n "${changed_files[1]:-}" ]; then
    now=$(date +%s); active=0
    for f in "${changed_files[@]}"; do
      [ -f "$repo/$f" ] || continue
      mt=$(stat -f %m "$repo/$f" 2>/dev/null) || continue
      if [ $(( now - mt )) -lt $(( GUARD_MIN * 60 )) ]; then active=1; break; fi
    done
    if [ "$active" = 1 ]; then
      log "[$name] ПРОПУСК — активное редактирование (<${GUARD_MIN} мин); back-up в следующий проход"
      continue
    fi
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
    # --no-verify намеренно: бэкап сохраняет состояние диска, а не судит качество кода.
    # В Hybrid System стоит pre-commit хук (страж канона коллекции) — без этого флага одно
    # нарушение в рабочем дереве тихо остановило бы авто-бэкап на все следующие прогоны.
    # Само нарушение никуда не денется: ручной коммит хук по-прежнему блокирует.
    if git -C "$repo" commit -q --no-verify -m "$msg" 2>>"$LOG"; then
      log "[$name] коммит: $msg"
    else
      log "[$name] ОШИБКА коммита"
      continue
    fi
  fi

  # push — всегда, чтобы подхватить и ручные неотправленные коммиты
  if git -C "$repo" remote | grep -q .; then
    if git -C "$repo" "${GIT_AUTH[@]}" push -q 2>>"$LOG"; then
      log "[$name] push выполнен"
    else
      log "[$name] ОШИБКА push (нет сети/токен/удалённый репозиторий?)"
    fi
  else
    log "[$name] remote не настроен — push пропущен"
  fi
done


log "=== конец авто-бэкапа ==="
