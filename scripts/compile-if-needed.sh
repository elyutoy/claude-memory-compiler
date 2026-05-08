#!/bin/bash
# Run compile.py only if today's daily log hasn't been successfully compiled yet.
# Scheduled every 2 hours; exits silently if today is already done.

PROJ="/Volumes/Work/Users/geg/Мои проекты/Ai Projects/claude-memory-compiler"
UV="/Volumes/Work/Users/geg/.local/bin/uv"
STATE="$PROJ/scripts/state.json"
TODAY=$(date +%Y-%m-%d)

# Already compiled successfully today (no "error" key in state entry)?
if python3 - <<EOF 2>/dev/null
import json, sys
try:
    state = json.load(open("$STATE"))
    entry = state.get("ingested", {}).get("${TODAY}.md", {})
    sys.exit(0 if (entry and "error" not in entry) else 1)
except Exception:
    sys.exit(1)
EOF
then
    exit 0
fi

cd "$PROJ" && "$UV" run python scripts/compile.py >> scripts/compile.log 2>&1
