"""
Compile daily conversation logs into structured knowledge articles.

This is the "LLM compiler" - it reads daily logs (source code) and produces
organized knowledge articles (the executable).

Usage:
    uv run python compile.py                    # compile new/changed logs only
    uv run python compile.py --all              # force recompile everything
    uv run python compile.py --file daily/2026-04-01.md  # compile a specific log
    uv run python compile.py --dry-run          # show what would be compiled
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

from config import COMPILE_RULES_FILE, CONCEPTS_DIR, CONNECTIONS_DIR, DAILY_DIR, KNOWLEDGE_DIR, now_iso
from utils import (
    file_hash,
    list_raw_files,
    list_wiki_articles,
    load_relevant_articles,
    load_state,
    read_wiki_index_compact,
    save_state,
)

# ── Paths for the LLM to use ──────────────────────────────────────────
ROOT_DIR = Path(__file__).resolve().parent.parent


def _parse_compilation_output(text: str) -> dict:
    """Parse structured output from the LLM into articles, index entries, log entry."""
    import re
    articles = []
    for m in re.finditer(
        r'<article\s+path="([^"]+)"\s+action="([^"]+)">(.*?)</article>',
        text,
        re.DOTALL,
    ):
        articles.append({
            "path": m.group(1).strip(),
            "action": m.group(2).strip(),
            "content": m.group(3).strip(),
        })

    index_entries = ""
    m = re.search(r"<index_entries>(.*?)</index_entries>", text, re.DOTALL)
    if m:
        index_entries = m.group(1).strip()

    log_entry = ""
    m = re.search(r"<log_entry>(.*?)</log_entry>", text, re.DOTALL)
    if m:
        log_entry = m.group(1).strip()

    return {"articles": articles, "index_entries": index_entries, "log_entry": log_entry}


def _apply_compilation(result: dict) -> int:
    """Write parsed compilation output to disk. Returns count of files written."""
    count = 0
    for article in result["articles"]:
        path = ROOT_DIR / article["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(article["content"] + "\n", encoding="utf-8")
        count += 1

    if result["index_entries"]:
        index_path = KNOWLEDGE_DIR / "index.md"
        existing = index_path.read_text(encoding="utf-8") if index_path.exists() else (
            "# Knowledge Base Index\n\n"
            "| Article | Summary | Compiled From | Updated |\n"
            "|---------|---------|---------------|---------|"
        )
        index_path.write_text(existing.rstrip() + "\n" + result["index_entries"] + "\n", encoding="utf-8")

    if result["log_entry"]:
        log_path = KNOWLEDGE_DIR / "log.md"
        existing = log_path.read_text(encoding="utf-8") if log_path.exists() else ""
        log_path.write_text(existing.rstrip() + "\n\n" + result["log_entry"] + "\n", encoding="utf-8")

    return count


async def compile_daily_log(log_path: Path, state: dict) -> float:
    """Compile a single daily log into knowledge articles.

    Single-pass approach: no tools, max_turns=1. The LLM outputs all articles
    as structured XML blocks; Python writes them to disk. This avoids the
    multi-turn overhead of the old tool-calling approach (~30 turns → 1 turn).

    Returns the API cost of the compilation.
    """
    from claude_agent_sdk import (
        AssistantMessage,
        ClaudeAgentOptions,
        ResultMessage,
        TextBlock,
        query,
    )

    # Filter out trivial lines that add noise without content
    raw_log = log_path.read_text(encoding="utf-8")
    log_content = "\n".join(
        line for line in raw_log.splitlines()
        if "FLUSH_OK" not in line and "FLUSH_ERROR" not in line
    ).strip()

    schema = COMPILE_RULES_FILE.read_text(encoding="utf-8")
    # Variant 2: compact index (slug + summary only, no dates/sources columns)
    wiki_index = read_wiki_index_compact()
    # Smart pre-load: only articles whose slug appears in the daily log
    relevant = load_relevant_articles(log_content)
    timestamp = now_iso()
    today = timestamp[:10]

    existing_articles_section = ""
    if relevant:
        parts = [f"### {path}\n\n{content}" for path, content in relevant.items()]
        existing_articles_section = (
            "\n## Existing Articles (pre-loaded for updating)\n\n"
            + "\n\n---\n\n".join(parts)
            + "\n"
        )

    prompt = f"""You are a knowledge compiler. Read the daily log and output wiki articles in the structured format below.

## Schema

{schema}

## Existing Articles in Wiki

{wiki_index}
{existing_articles_section}
## Daily Log to Compile

**File:** {log_path.name}

{log_content}

## Output Format

Output ONLY the following XML blocks — no prose, no explanations.

For each article to create or update:
```
<article path="knowledge/concepts/slug.md" action="create">
---
title: "..."
aliases: [...]
tags: [...]
sources:
  - "daily/{log_path.name}"
created: {today}
updated: {today}
---

# Title

...full article content...
</article>
```

For updating an existing article, use `action="update"` and provide the COMPLETE updated file content (not just the diff). Only update if the log genuinely adds new information to that article.

For new index rows (one per new article):
```
<index_entries>
| [[concepts/slug]] | One-line summary | daily/{log_path.name} | {today} |
</index_entries>
```

For the build log:
```
<log_entry>
## [{timestamp}] compile | {log_path.name}
- Source: daily/{log_path.name}
- Articles created: [[concepts/x]]
- Articles updated: [[concepts/y]]
</log_entry>
```

## Quality Rules
- Extract 3-7 distinct concepts
- Every article: complete YAML frontmatter, ≥2 wikilinks, ≥2 Related Concepts entries
- Key Points: 3-5 bullets; Details: 2+ paragraphs
- Prefer updating existing articles over creating near-duplicates
"""

    cost = 0.0
    last_error = None

    for attempt in range(1, 4):
        cost = 0.0
        response = ""
        try:
            async for message in query(
                prompt=prompt,
                options=ClaudeAgentOptions(
                    cwd=str(ROOT_DIR),
                    allowed_tools=[],
                    max_turns=1,
                ),
            ):
                if isinstance(message, AssistantMessage):
                    for block in message.content:
                        if isinstance(block, TextBlock):
                            response += block.text
                elif isinstance(message, ResultMessage):
                    cost = message.total_cost_usd or 0.0
                    print(f"  Cost: ${cost:.4f}")

            result = _parse_compilation_output(response)
            written = _apply_compilation(result)
            print(f"  Written: {written} file(s), {len(result['articles'])} article(s)")
            last_error = None
            break
        except Exception as e:
            last_error = e
            if attempt < 3:
                import time as _time
                print(f"  Attempt {attempt} failed: {e} — retrying in 10s...")
                _time.sleep(10)
            else:
                print(f"  Error after 3 attempts: {e}")

    rel_path = log_path.name
    state.setdefault("ingested", {})[rel_path] = {
        "hash": file_hash(log_path),
        "compiled_at": now_iso(),
        "cost_usd": cost,
        **({"error": str(last_error)} if last_error else {}),
    }
    state["total_cost"] = state.get("total_cost", 0.0) + cost
    save_state(state)

    return cost


def main():
    parser = argparse.ArgumentParser(description="Compile daily logs into knowledge articles")
    parser.add_argument("--all", action="store_true", help="Force recompile all logs")
    parser.add_argument("--file", type=str, help="Compile a specific daily log file")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be compiled")
    args = parser.parse_args()

    state = load_state()

    # Determine which files to compile
    if args.file:
        target = Path(args.file)
        if not target.is_absolute():
            target = DAILY_DIR / target.name
        if not target.exists():
            # Try resolving relative to project root
            target = ROOT_DIR / args.file
        if not target.exists():
            print(f"Error: {args.file} not found")
            sys.exit(1)
        to_compile = [target]
    else:
        all_logs = list_raw_files()
        if args.all:
            to_compile = all_logs
        else:
            to_compile = []
            for log_path in all_logs:
                rel = log_path.name
                prev = state.get("ingested", {}).get(rel, {})
                if not prev or prev.get("hash") != file_hash(log_path):
                    to_compile.append(log_path)

    if not to_compile:
        print("Nothing to compile - all daily logs are up to date.")
        return

    print(f"{'[DRY RUN] ' if args.dry_run else ''}Files to compile ({len(to_compile)}):")
    for f in to_compile:
        print(f"  - {f.name}")

    if args.dry_run:
        return

    # Compile each file sequentially
    total_cost = 0.0
    for i, log_path in enumerate(to_compile, 1):
        print(f"\n[{i}/{len(to_compile)}] Compiling {log_path.name}...")
        cost = asyncio.run(compile_daily_log(log_path, state))
        total_cost += cost
        print(f"  Done.")

    articles = list_wiki_articles()
    print(f"\nCompilation complete. Total cost: ${total_cost:.2f}")
    print(f"Knowledge base: {len(articles)} articles")


if __name__ == "__main__":
    main()
