#!/bin/zsh
# Еженедельный внешний бэкап на SMB Distrib: база ChromaDB + archive/.
#
# Оба скрипта существовали и раньше, но звались руками «раз в 1-2 недели по памяти» —
# то есть иногда никогда. Ровно так молчал backup-repos.sh, пока не выяснилось, что он
# месяц не пушил: пропуск, о котором не сообщают, неотличим от успеха (класс К1 аудита 14.08).
# Поэтому здесь главное не запуск, а отчёт: результат уходит в Telegram ВСЕГДА, включая
# «диск не примонтирован» — выключенный NAS иначе тихо съест весь бэкап.
#
# Два способа вызова:
#   backup-external.sh             — по расписанию (вс 18:00) и руками: делать всегда, отчёт всегда
#   backup-external.sh --if-stale  — догон при монтировании тома: делать, только если копия протухла
set -u

BASE="/Volumes/Work/Users/geg/Мои проекты/Ai Projects"
LOG="$BASE/claude-memory-compiler/scripts/backup-external.log"
DEST_ROOT="${BACKUP_DEST_ROOT:-/Volumes/Distrib/backup}"
STAMP="$BASE/claude-memory-compiler/scripts/.backup-external-last"
LOCK="$BASE/claude-memory-compiler/scripts/.backup-external.lock"
STALE_DAYS="${BACKUP_STALE_DAYS:-6}"

log() { print "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG" }

# Без parse_mode: разметка в служебном уведомлении — лишний способ его не доставить.
# Недельный отчёт аудита 23.08 не дошёл именно из-за одного символа в HTML (HTTP 400).
notify() {
  local env_file="$BASE/Hybrid System/scripts/.env" token chat
  [[ -f "$env_file" ]] || return 0
  token=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$env_file" | cut -d= -f2- | tr -d '"' | tr -d "'")
  chat=$(grep -m1 '^TELEGRAM_AUDIT_CHAT_ID=' "$env_file" | cut -d= -f2- | tr -d '"' | tr -d "'")
  [[ -n "$token" && -n "$chat" ]] || return 0
  local resp
  resp=$(curl -s -m 15 "https://api.telegram.org/bot$token/sendMessage" \
              --data-urlencode "chat_id=$chat" --data-urlencode "text=$1")
  # Отчёт о бэкапе, не доехавший в Telegram, — тот же молчаливый пропуск.
  if [[ "$resp" == *'"ok":true'* ]]; then log "Telegram sent: True"
  else log "Telegram sent: False — ${resp:0:120}"; fi
}

# ── Догоняющий запуск (--if-stale) ────────────────────────────────────────────
# Расписание слепо: диск выключен в воскресенье 18:00 — копия ждёт следующего
# воскресенья (так и вышло 30.08: пропуск, бэкап пришлось звать руками 31.08).
# Агент com.aiprojects.backup-external-onmount зовёт этот же скрипт с --if-stale
# при монтировании ЛЮБОГО тома. Отсюда два тихих гейта: копия свежая — выходим,
# смонтирован не Distrib — выходим. Молчание тут принципиально: иначе всякая
# флешка в порту шлёт в Telegram «пропуск» и обесценивает те самые уведомления,
# ради которых скрипт и писался.
CATCHUP=0
[[ "${1:-}" == "--if-stale" ]] && CATCHUP=1

if (( CATCHUP )); then
  if [[ -f "$STAMP" ]]; then
    age_days=$(( ( $(date +%s) - $(stat -f %m "$STAMP") ) / 86400 ))
    if (( age_days < STALE_DAYS )); then
      log "догон: пропуск, копии $age_days дн. (порог $STALE_DAYS)"
      exit 0
    fi
    log "догон: копии $age_days дн. — пора"
  else
    log "догон: отметки о прошлом бэкапе нет — считаем протухшим"
  fi
  # SMB-том появляется в /Volumes не в момент события монтирования, а через
  # несколько секунд после; ждём до минуты, потом молча уходим.
  for i in {1..12}; do [[ -d "$DEST_ROOT" ]] && break; sleep 5; done
  if [[ ! -d "$DEST_ROOT" ]]; then
    log "догон: смонтирован не Distrib — выход"
    exit 0
  fi
fi

if [[ ! -d "$DEST_ROOT" ]]; then
  log "ПРОПУСК: $DEST_ROOT не примонтирован"
  notify "⚠️ Внешний бэкап пропущен: диск Distrib не примонтирован. База ChromaDB и archive/ остались без свежей копии."
  exit 0
fi

# Расписание и догон — разные job-ы launchd, и в воскресенье они могут совпасть.
# Два rsync на одну папку по SMB — гарантированная порча снимка, поэтому второй уходит.
# Владелец записан внутрь: без этого достаточно одного kill -9 или ребута посреди rsync,
# чтобы брошенный каталог навсегда и молча выключил бэкап — ровно тот молчаливый
# пропуск, против которого писался весь отчёт в Telegram.
if ! mkdir "$LOCK" 2>/dev/null; then
  owner=$(cat "$LOCK/pid" 2>/dev/null)
  if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
    log "ПРОПУСК: другой прогон уже идёт (pid $owner)"
    exit 0
  fi
  log "перехват брошенного lock (владелец ${owner:-неизвестен} мёртв)"
fi
print $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT

# Размер снимка берём из статистики rsync, а не из du: под launchd du на сетевом
# томе получает «Operation not permitted» (TCC не пускает агента на SMB), и отчёт
# 31.08 ушёл в Telegram с пустыми цифрами. Сам rsync по дереву уже прошёл — его
# «total size is» бесплатно и тому же ограничению не подчиняется.
typeset -a failed
SIZE_OUT=""
run() {  # $1 = что, $2 = скрипт; выставляет SIZE_OUT (байты снимка)
  log "→ $1"
  local out rc
  out=$("$2" 2>&1); rc=$?
  print -r -- "$out" >> "$LOG"
  SIZE_OUT=$(print -r -- "$out" | awk '/total size is/ {gsub(",", "", $4); print $4}' | tail -1)
  if (( rc == 0 )); then log "✓ $1"; else log "✗ $1"; failed+=("$1"); fi
}
human() {  # байты → человеческий размер; пусто на входе → «?»
  [[ -n "${1:-}" ]] || { print "?"; return }
  awk -v b="$1" 'BEGIN { if (b >= 1073741824) printf "%.1f ГБ", b/1073741824
                         else if (b >= 1048576) printf "%.0f МБ", b/1048576
                         else printf "%d Б", b }'
}
run "база ChromaDB" "$BASE/Hybrid System/scripts/backup_chromadb.sh"; DB_SIZE=$(human "$SIZE_OUT")
run "archive"       "$BASE/claude-memory-compiler/scripts/backup-archive.sh"; AR_SIZE=$(human "$SIZE_OUT")

if (( ${#failed} > 0 )); then
  notify "🔴 Внешний бэкап на Distrib: не удалось — ${(j:, :)failed}. Смотри claude-memory-compiler/scripts/backup-external.log"
  exit 1
fi

# Отметка ставится только после успеха обоих rsync — иначе догон будет считать
# копию свежей после неудачного прогона.
touch "$STAMP"

log "✓ всё обновлено (база $DB_SIZE, archive $AR_SIZE)"
(( CATCHUP )) && WHY=" (догон после пропуска)" || WHY=""
notify "✓ Внешний бэкап на Distrib обновлён$WHY: база ChromaDB $DB_SIZE, archive $AR_SIZE — $(date '+%d.%m %H:%M')"
