"""
SessionStart hook - injects knowledge base context into every conversation.

This is the "context injection" layer. When Claude Code starts a session,
this hook reads the knowledge base index and recent daily log, then injects
them as additional context so Claude always "remembers" what it has learned.

Configure in .claude/settings.json:
{
    "hooks": {
        "SessionStart": [{
            "matcher": "",
            "command": "uv run python hooks/session-start.py"
        }]
    }
}
"""

import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Paths relative to project root
ROOT = Path(__file__).resolve().parent.parent
KNOWLEDGE_DIR = ROOT / "knowledge"
DAILY_DIR = ROOT / "daily"
INDEX_FILE = KNOWLEDGE_DIR / "index.md"

MAX_CONTEXT_CHARS = 8_000
MAX_LOG_LINES = 15


def get_recent_log() -> str:
    """Read the most recent daily log within the last week (today back to 6 days ago).

    Returns the first existing log walking back from today, so a multi-day gap
    (weekend, switching projects) no longer leaves the session with no memory.
    Still one file / MAX_LOG_LINES lines — context size is unchanged.
    """
    today = datetime.now(timezone.utc).astimezone()

    for offset in range(7):
        date = today - timedelta(days=offset)
        log_path = DAILY_DIR / f"{date.strftime('%Y-%m-%d')}.md"
        if log_path.exists():
            lines = log_path.read_text(encoding="utf-8").splitlines()
            # Return last N lines to keep context small
            recent = lines[-MAX_LOG_LINES:] if len(lines) > MAX_LOG_LINES else lines
            return "\n".join(recent)

    return "(no recent daily log)"


def build_knowledge_map() -> str:
    """Compact map of all knowledge articles — slugs grouped by topic, no summaries.

    The full index.md (~23 KB at 120 articles) overflows MAX_CONTEXT_CHARS and is
    truncated mid-list, silently dropping the tail. A slug-only map keeps the WHOLE
    set of articles visible; details are pulled on demand (this is the query-based
    layer — lazy, not blind injection at startup where there is no query yet):
      - summaries -> knowledge/index.md
      - full text -> knowledge/concepts/<slug>.md
      - content search -> uv run python scripts/query.py "<question>"
    """
    concepts_dir = KNOWLEDGE_DIR / "concepts"
    slugs = sorted(p.stem for p in concepts_dir.glob("*.md")) if concepts_dir.exists() else []
    if not slugs:
        return "## Knowledge Base Map\n\n(empty - no articles compiled yet)"

    groups: dict[str, list[str]] = {}
    for slug in slugs:
        topic = slug.split("-", 1)[0]
        groups.setdefault(topic, []).append(slug)

    lines = [
        f"## Knowledge Base Map ({len(slugs)} articles)",
        "",
        "Slugs only — pull details on demand: summaries -> knowledge/index.md · "
        "full text -> knowledge/concepts/<slug>.md · "
        'search -> `uv run python scripts/query.py "<question>"`',
        "",
    ]
    for topic in sorted(groups):
        lines.append(f"**{topic}** ({len(groups[topic])}): " + " · ".join(groups[topic]))
    return "\n".join(lines)


def build_context() -> str:
    """Assemble the context to inject into the conversation."""
    parts = []

    # Today's date
    today = datetime.now(timezone.utc).astimezone()
    parts.append(f"## Today\n{today.strftime('%A, %B %d, %Y')}")

    # Knowledge base — compact slug map. The full index.md (~23 KB) overflows
    # MAX_CONTEXT_CHARS and gets truncated mid-list; the map keeps every article
    # visible and details are pulled on demand (see build_knowledge_map docstring).
    parts.append(build_knowledge_map())

    # Recent daily log
    recent_log = get_recent_log()
    parts.append(f"## Recent Daily Log\n\n{recent_log}")

    context = "\n\n---\n\n".join(parts)

    # Truncate if too long
    if len(context) > MAX_CONTEXT_CHARS:
        context = context[:MAX_CONTEXT_CHARS] + "\n\n...(truncated)"

    return context


def main():
    context = build_context()

    output = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context,
        }
    }

    print(json.dumps(output))


if __name__ == "__main__":
    main()
