# drafts/

In diesem Ordner liegen Artikel-Drafts während der Pipeline.

**Wichtig:** Astro baut diese Dateien NICHT — sie sind keine Content Collection
und werden weder in `articles/` noch in `articles_states` synchronisiert.

## Wer schreibt hierher

- **Manus** legt einen Draft an, wenn ein Topic von `discovered` → `drafted` wechselt.
  Datei-Pfad: `src/content/drafts/<slug>.md`. Topic-Eintrag bekommt `draft_path` gesetzt.
- **Claude** liest den Draft, poliert die Sprache, schreibt zurück, setzt Status `polished`.
- **Manus** macht den finalen DOI-Check, **verschiebt die Datei** nach `src/content/artikel/<slug>.md`,
  setzt Topic-Status `published` (mit `article_slug`).

## Format

Markdown mit YAML-Frontmatter, gleiche Struktur wie veröffentlichte Artikel.
Zusätzlich im Frontmatter ein `sources:`-Array mit verifizierten Quellen.

Siehe `docs/CLAUDE_WRITING_RULES.md` und `docs/MANUS_INSTRUCTIONS.md` für Details.
