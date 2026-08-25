#!/bin/zsh
# Еженедельный внешний бэкап на SMB Distrib: база ChromaDB + archive/.
#
# Оба скрипта существовали и раньше, но звались руками «раз в 1-2 недели по памяти» —
# то есть иногда никогда. Ровно так молчал backup-repos.sh, пока не выяснилось, что он
# месяц не пушил: пропуск, о котором не сообщают, неотличим от успеха (класс К1 аудита 14.08).
# Поэтому здесь главное не запуск, а отчёт: результат уходит в Telegram ВСЕГДА, включая
# «диск не примонтирован» — выключенный NAS иначе тихо съест весь бэкап.
set -u

BASE="/Volumes/Work/Users/geg/Мои проекты/Ai Projects"
LOG="$BASE/claude-memory-compiler/scripts/backup-external.log"
DEST_ROOT="/Volumes/Distrib/backup"

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

if [[ ! -d "$DEST_ROOT" ]]; then
  log "ПРОПУСК: $DEST_ROOT не примонтирован"
  notify "⚠️ Внешний бэкап пропущен: диск Distrib не примонтирован. База ChromaDB и archive/ остались без свежей копии."
  exit 0
fi

typeset -a failed
run() {  # $1 = что, $2 = скрипт
  log "→ $1"
  if "$2" >> "$LOG" 2>&1; then log "✓ $1"; else log "✗ $1"; failed+=("$1"); fi
}
run "база ChromaDB" "$BASE/Hybrid System/scripts/backup_chromadb.sh"
run "archive"       "$BASE/claude-memory-compiler/scripts/backup-archive.sh"

if (( ${#failed} > 0 )); then
  notify "🔴 Внешний бэкап на Distrib: не удалось — ${(j:, :)failed}. Смотри claude-memory-compiler/scripts/backup-external.log"
  exit 1
fi

DB_SIZE=$(du -sh "$DEST_ROOT/HybridSystem_ChromaDB/database" 2>/dev/null | cut -f1)
AR_SIZE=$(du -sh "$DEST_ROOT/AiProjects_archive" 2>/dev/null | cut -f1)
log "✓ всё обновлено (база $DB_SIZE, archive $AR_SIZE)"
notify "✓ Внешний бэкап на Distrib обновлён: база ChromaDB $DB_SIZE, archive $AR_SIZE — $(date '+%d.%m %H:%M')"
