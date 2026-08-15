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

# Момент старта прохода. Файлы, записанные ПОСЛЕ него, — работа самого бэкапа
# (sync.sh обновляет зеркало system-config прямо перед циклом), а не редактирование
# человека. Без этой отсечки бэкап блокирует сам себя: пишет в репозиторий на первых
# секундах прохода, а гейт секундой позже видит файл свежим и пропускает репозиторий.
# Так и вышло с убранным отсюда проектом — 71 проход подряд мимо, копии не было 18 дней;
# у system-config механика та же и ждала своего часа. Класс К2 аудита 14.08: сторож
# (здесь — гейт) сам создаёт отказ, который должен предотвращать.
PASS_START=$(date +%s)

# Отсрочка не может быть вечной. Гейт откладывает коммит, пока идёт правка, но если
# работа лежит незакоммиченной дольше MAX_DEFER_H часов, бэкап делается всё равно —
# отдельным WIP-коммитом и с уведомлением. Потеря дня работы дороже некрасивой истории.
GUARD_MIN="${BACKUP_GUARD_MIN:-30}"
MAX_DEFER_H="${BACKUP_MAX_DEFER_H:-6}"
DEFER_DIR="$BASE/.backup-deferred"
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

# Уведомление в тот же Telegram, куда ходит недельный аудит. Лог — для разбора,
# Telegram — для обнаружения: 18 дней без бэкапа прожили именно потому, что «ПРОПУСК»
# писался только в файл, который открывают раз в месяц (класс К1 аудита 14.08).
notify() {
  local env_file="$BASE/Hybrid System/scripts/.env" token chat
  [ -f "$env_file" ] || return 0
  token=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$env_file" | cut -d= -f2- | tr -d '"' | tr -d "'")
  chat=$(grep -m1 '^TELEGRAM_AUDIT_CHAT_ID=' "$env_file" | cut -d= -f2- | tr -d '"' | tr -d "'")
  [ -n "$token" ] && [ -n "$chat" ] || return 0
  curl -s -m 15 -o /dev/null "https://api.telegram.org/bot$token/sendMessage" \
    --data-urlencode "chat_id=$chat" --data-urlencode "text=$1" 2>>"$LOG" || true
}

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
  #
  # Две поправки от 2026-08-15, обе — по следам аудита 14.08:
  #  • файлы, записанные этим же проходом (PASS_START), редактированием не считаются:
  #    иначе бэкап блокирует сам себя своим же snapshot-шагом;
  #  • отсрочка ограничена MAX_DEFER_H часами. Гейт умеет только откладывать, и при
  #    непрерывной работе откладывал бы бесконечно — целый день правок оставался бы
  #    вообще без копии, а «ПРОПУСК» лежал бы в логе, который никто не читает.
  defer_file="$DEFER_DIR/$name"
  force_wip=0
  waited_h=0
  changed_files=("${(@f)$(git -C "$repo" ls-files -m -o --exclude-standard 2>/dev/null)}")
  if [ -n "${changed_files[1]:-}" ]; then
    now=$(date +%s); active=0
    for f in "${changed_files[@]}"; do
      [ -f "$repo/$f" ] || continue
      mt=$(stat -f %m "$repo/$f" 2>/dev/null) || continue
      [ "$mt" -ge "$PASS_START" ] && continue      # это наша же запись, а не правка человека
      if [ $(( now - mt )) -lt $(( GUARD_MIN * 60 )) ]; then active=1; break; fi
    done
    if [ "$active" = 1 ]; then
      mkdir -p "$DEFER_DIR" 2>>"$LOG"
      [ -f "$defer_file" ] || echo "$now" > "$defer_file"
      first=$(cat "$defer_file" 2>/dev/null) || first="$now"
      waited_h=$(( (now - first) / 3600 ))
      if [ "$waited_h" -ge "$MAX_DEFER_H" ]; then
        force_wip=1        # хватит откладывать: сохраняем как есть, помечая коммит
        log "[$name] отсрочка ${waited_h} ч ≥ ${MAX_DEFER_H} ч — коммичу как WIP, работа не останется без копии"
      else
        log "[$name] ПРОПУСК — активное редактирование (<${GUARD_MIN} мин), отсрочка ${waited_h}/${MAX_DEFER_H} ч"
        continue
      fi
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
    rm -f "$defer_file"
  else
    count=$(git -C "$repo" diff --cached --name-only | wc -l | tr -d ' ')
    msg="Авто-бэкап $(date '+%Y-%m-%d %H:%M') (${count} файлов)"
    if [ "$force_wip" = 1 ]; then
      # Отдельная пометка, чтобы такой коммит было видно в истории: это снимок
      # незаконченной работы, а не осмысленное изменение. Разложить по темам — руками.
      msg="WIP-бэкап $(date '+%Y-%m-%d %H:%M') (${count} файлов) — лежало без коммита ${waited_h} ч, по темам не разложено"
    fi
    # --no-verify намеренно: бэкап сохраняет состояние диска, а не судит качество кода.
    # В Hybrid System стоит pre-commit хук (страж канона коллекции) — без этого флага одно
    # нарушение в рабочем дереве тихо остановило бы авто-бэкап на все следующие прогоны.
    # Само нарушение никуда не денется: ручной коммит хук по-прежнему блокирует.
    if git -C "$repo" commit -q --no-verify -m "$msg" 2>>"$LOG"; then
      log "[$name] коммит: $msg"
      rm -f "$defer_file"
      if [ "$force_wip" = 1 ]; then
        notify "💾 Авто-бэкап: в «$name» ${count} файлов лежали без коммита ${waited_h} ч — сохранил их WIP-коммитом.
Работа не потеряется, но история не разложена по темам: закоммить их осмысленно, когда закончишь."
      fi
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
