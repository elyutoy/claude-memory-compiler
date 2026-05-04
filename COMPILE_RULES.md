# COMPILE_RULES.md — Knowledge Compiler Schema

Compact version of AGENTS.md for use by compile.py. Full reference: AGENTS.md.

## Article Formats

### Concept (`knowledge/concepts/<slug>.md`)

```markdown
---
title: "Concept Name"
aliases: [alternate-name]
tags: [domain, topic]
sources:
  - "daily/YYYY-MM-DD.md"
created: YYYY-MM-DD
updated: YYYY-MM-DD
---

# Concept Name

[2-4 sentence core explanation]

## Key Points
- [3-5 self-contained bullets]

## Details
[2+ encyclopedia-style paragraphs]

## Related Concepts
- [[concepts/related]] — how it connects

## Sources
- [[daily/YYYY-MM-DD.md]] — what was learned
```

### Connection (`knowledge/connections/<slug>.md`)

```markdown
---
title: "Connection: X and Y"
connects:
  - "concepts/concept-x"
  - "concepts/concept-y"
sources:
  - "daily/YYYY-MM-DD.md"
created: YYYY-MM-DD
updated: YYYY-MM-DD
---

# Connection: X and Y

## The Connection
[What links these concepts]

## Key Insight
[The non-obvious relationship]

## Related Concepts
- [[concepts/concept-x]]
- [[concepts/concept-y]]
```

### Q&A (`knowledge/qa/<slug>.md`)

```markdown
---
title: "Q: Original Question"
question: "exact question"
consulted:
  - "concepts/article"
filed: YYYY-MM-DD
---

# Q: Original Question

## Answer
[Synthesized answer with [[wikilinks]]]

## Sources Consulted
- [[concepts/article]] — relevant because...
```

## Compilation Steps

When processing a daily log:

1. Read the daily log
2. Read `knowledge/index.md` to understand current state
3. Read existing articles that may need updating
4. For each piece of knowledge:
   - Existing topic → **UPDATE** the concept article, add source
   - New topic → **CREATE** a new `concepts/` article
5. Non-obvious link between 2+ concepts → **CREATE** a `connections/` article
6. **UPDATE** `knowledge/index.md` — add/modify entries:
   `| [[path/slug]] | One-line summary | daily/file.md | YYYY-MM-DD |`
7. **APPEND** to `knowledge/log.md`:
   ```
   ## [ISO-timestamp] compile | filename.md
   - Source: daily/filename.md
   - Articles created: [[concepts/x]]
   - Articles updated: [[concepts/y]]
   ```

## Quality Rules

- Extract 3-7 distinct concepts per daily log
- Prefer updating existing articles over near-duplicates
- Every article: complete YAML frontmatter, ≥2 wikilinks, ≥2 Related Concepts entries
- Key Points: 3-5 bullets; Details: 2+ paragraphs
- Write in encyclopedia style — factual, neutral, self-contained

## Conventions

- Wikilinks: `[[concepts/slug]]` (no .md extension, full path from knowledge/)
- File names: lowercase, hyphens (`supabase-row-level-security.md`)
- Dates: ISO 8601 (YYYY-MM-DD)
- Every article must link back to its source daily log(s)
