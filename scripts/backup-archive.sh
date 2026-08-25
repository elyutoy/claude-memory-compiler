#!/bin/zsh
# Бэкап archive/ — завершённых проектов Ai Projects — на внешний носитель.
#
# archive/ лежит вне git осознанно: 3 ГБ сырья (63 mp3 курса Уокопа и прочее), а по
# правилу «репо = код+docs+wiki» сырьё в репозиторий не кладём. Но 250 МБ рядом с ними —
# транскрипты, переводы, воркбуки и SVG-схемы — не восстановимы ниоткуда, и до 25.08.2026
# их не покрывала ни одна копия: backup_chromadb.sh берёт только database/, Time Machine —
# только HOME. Этот скрипт закрывает дыру целиком, не разбирая, что ценнее: rsync шлёт
# дельту, поэтому повторный прогон стоит секунды независимо от объёма.
#
# Использование: ./scripts/backup-archive.sh [путь-к-папке-бэкапа]
# По умолчанию:  /Volumes/Distrib/backup/AiProjects_archive (сетевой SMB-диск GigaGEG)
set -u

SRC="/Volumes/Work/Users/geg/Мои проекты/Ai Projects/archive"
DEST="${1:-/Volumes/Distrib/backup/AiProjects_archive}"
DEST_ROOT="$(dirname "$DEST")"

# GNU rsync (brew) надёжнее системного openrsync на больших деревьях; fallback — системный.
RSYNC="/opt/homebrew/bin/rsync"
if [[ -x "$RSYNC" ]]; then PROG="--info=progress2"; else RSYNC="rsync"; PROG="--progress"; fi
# Под launchd прогресс уходит в файл \r-строками и делает лог нечитаемым
# (первый прогон backup-external, 25.08.2026). Показываем только человеку.
[[ -t 1 ]] || PROG="--stats"

if [[ ! -d "$DEST_ROOT" ]]; then
  echo "✗ Целевой диск не примонтирован: $DEST_ROOT"; exit 1
fi
if [[ ! -d "$SRC" ]]; then
  echo "✗ Не найден archive: $SRC"; exit 1
fi

mkdir -p "$DEST"
echo "→ Копирую archive на $DEST ($RSYNC, дельта)…"
if ! "$RSYNC" -a --delete $PROG --exclude='.DS_Store' "$SRC/" "$DEST/"; then
  echo "✗ rsync завершился с ошибкой — снимок НЕ обновлён"; exit 1
fi

SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1)
echo "✓ Готово. Снимок: $DEST ($SIZE), $(date '+%Y-%m-%d %H:%M')"
